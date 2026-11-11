// SPDX-License-Identifier: MIT
//! Hyper's VM networking: what each VM's [`NetId`] maps to.
//!
//! Laws the tests hold this to:
//! - every `NetId` gets its own transit `/30`, and no two overlap;
//! - a VM's host and uplink addresses share its `/30` and are neither its network nor its
//!   broadcast address;
//! - an uplink address maps back to exactly the `NetId` it came from, and nothing else
//!   maps to one;
//! - a VM's IPv6 address sits in `<prefix>:1::/80` and its low bits are its `NetId`.

pub mod firewall;
pub mod host;
pub mod vm;

use derive_more::Display;
use hyperrs_linux::net::nft::{Action, Chain, ChainType, Hook, Iface, Match, Policy, Rule};
use hyperrs_linux::net::{IfName, IpNet, IpNetParseError, Ipv4Net, Ipv6Net};
use serde::Deserialize;
use std::net::{AddrParseError, Ipv4Addr, Ipv6Addr};
use std::str::FromStr;
use thiserror::Error as ThisError;

/// Every VM's transit `/30` comes out of `10.200.0.0/16`.
const TRANSIT: Ipv4Addr = Ipv4Addr::new(10, 200, 0, 0);
const TRANSIT_PREFIX: u8 = 16;
const TRANSIT_SUBNET_PREFIX: u8 = 30;
const TRANSIT_SUBNET_ADDRS: u32 = 4;
const HOST_END: u32 = 1;
const UPLINK_END: u32 = 2;

/// VM addresses come out of `<prefix>:1::/80`.
const VM_RANGE_PREFIX: u8 = 80;
const VM_RANGE_TAG: u128 = 1 << 48;
const NODE_PREFIX_MAX: u8 = 64;

const TABLE: &str = "hyper";
const FIREWALL_TABLE: &str = "hyper-firewall";
const DSTNAT_PRIORITY: i32 = -100;
const SRCNAT_PRIORITY: i32 = 100;
const FILTER_PRIORITY: i32 = 0;

/// Where VMs may not send: private, shared (CGNAT) and link-local ranges, which is
/// where providers keep their infrastructure and metadata services.
const NON_PUBLIC: [&str; 15] = [
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.0.0.0/24",
    "192.168.0.0/16",
    "198.18.0.0/15",
    "240.0.0.0/4",
    "64:ff9b::/96",
    "64:ff9b:1::/48",
    "2002::/16",
    "fc00::/7",
    "fec0::/10",
    "::ffff:0:0/96",
];

#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("net id {0} is past the last one, {max}", max = NetId::COUNT - 1)]
pub struct NetIdOutOfRange(u16);

/// A VM's index into this node's network address space, allocated by the BEAM.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Display, Deserialize)]
#[serde(try_from = "u16")]
pub struct NetId(u16);

impl TryFrom<u16> for NetId {
    type Error = NetIdOutOfRange;

    fn try_from(id: u16) -> Result<Self, Self::Error> {
        if id >= Self::COUNT {
            return Err(NetIdOutOfRange(id));
        }
        Ok(Self(id))
    }
}

impl NetId {
    /// How many VMs one node can network: one per `/30` in the transit range.
    pub const COUNT: u16 = 1 << (TRANSIT_SUBNET_PREFIX - TRANSIT_PREFIX);

    /// The range every VM's transit `/30` comes out of, `10.200.0.0/16`.
    pub fn transit_range() -> Ipv4Net {
        Ipv4Net {
            addr: TRANSIT,
            prefix: TRANSIT_PREFIX
                .try_into()
                .expect("a /16 is a valid IPv4 prefix"),
        }
    }

    /// The raw index.
    pub fn get(self) -> u16 {
        self.0
    }

    /// The host end of the VM's veth pair, `vm-veth-<id>`.
    pub fn host_veth(self) -> IfName {
        format!("vm-veth-{}", self.0)
            .parse()
            .expect("vm-veth-<id> is a valid interface name")
    }

    /// The host end's address in the VM's transit `/30`.
    pub fn host_addr(self) -> Ipv4Net {
        self.transit(HOST_END)
    }

    /// The namespace end's (`uplink`) address in the VM's transit `/30`.
    pub fn uplink_addr(self) -> Ipv4Net {
        self.transit(UPLINK_END)
    }

    /// The `NetId` whose [`NetId::uplink_addr`] is `addr`, if any.
    pub fn from_uplink_addr(addr: Ipv4Addr) -> Option<Self> {
        let offset = u32::from(addr).checked_sub(u32::from(TRANSIT))?;
        if offset % TRANSIT_SUBNET_ADDRS != UPLINK_END {
            return None;
        }
        u16::try_from(offset / TRANSIT_SUBNET_ADDRS)
            .ok()?
            .try_into()
            .ok()
    }

    fn transit(self, host: u32) -> Ipv4Net {
        let subnet = u32::from(TRANSIT) + TRANSIT_SUBNET_ADDRS * u32::from(self.0);
        Ipv4Net {
            addr: Ipv4Addr::from(subnet + host),
            prefix: TRANSIT_SUBNET_PREFIX
                .try_into()
                .expect("a /30 is a valid IPv4 prefix"),
        }
    }
}

#[derive(Debug, ThisError)]
pub enum NodePrefixError {
    #[error(transparent)]
    Parse(#[from] IpNetParseError),
    #[error("{0} is not an IPv6 prefix")]
    NotIpv6(IpNet),
    #[error("{0} is longer than /{NODE_PREFIX_MAX}, leaving no room for <prefix>:1::/80")]
    TooLong(Ipv6Net),
    #[error("{0} overlaps {1}, which VMs may not reach; use the uplink's public prefix")]
    NotPublic(Ipv6Net, Ipv6Net),
}

/// The node's routed IPv6 prefix, `/64` or shorter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
#[display("{_0}")]
pub struct NodePrefix(Ipv6Net);

impl FromStr for NodePrefix {
    type Err = NodePrefixError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let IpNet::V6(net) = s.parse()? else {
            return Err(NodePrefixError::NotIpv6(s.parse()?));
        };
        if net.prefix.get() > NODE_PREFIX_MAX {
            return Err(NodePrefixError::TooLong(net));
        }
        let overlapping = NON_PUBLIC
            .iter()
            .filter_map(
                |range| match range.parse().expect("the non-public ranges parse") {
                    IpNet::V6(range) => Some(range),
                    IpNet::V4(_) => None,
                },
            )
            .find(|range: &Ipv6Net| {
                let shorter = if net.prefix.get() <= range.prefix.get() {
                    net.prefix
                } else {
                    range.prefix
                };
                Ipv6Net {
                    addr: net.addr,
                    prefix: shorter,
                }
                .network()
                    == Ipv6Net {
                        addr: range.addr,
                        prefix: shorter,
                    }
                    .network()
            });
        if let Some(range) = overlapping {
            return Err(NodePrefixError::NotPublic(net, range));
        }
        Ok(Self(Ipv6Net {
            addr: net.network(),
            prefix: net.prefix,
        }))
    }
}

impl NodePrefix {
    pub fn get(self) -> Ipv6Net {
        self.0
    }

    /// `<prefix>:1::/80`, the range VM addresses come out of.
    pub fn vm_range(self) -> Ipv6Net {
        Ipv6Net {
            addr: Ipv6Addr::from(u128::from(self.0.addr) | VM_RANGE_TAG),
            prefix: VM_RANGE_PREFIX
                .try_into()
                .expect("a /80 is a valid IPv6 prefix"),
        }
    }

    /// The guest's address, `<prefix>:1:0:0:<id>`.
    pub fn guest(self, id: NetId) -> Ipv6Addr {
        Ipv6Addr::from(u128::from(self.vm_range().addr) | u128::from(id.get()))
    }

    pub fn guest_net_id(self, addr: Ipv6Addr) -> Option<NetId> {
        let range = self.vm_range();
        let offset = u128::from(addr).checked_sub(u128::from(range.addr))?;
        if (Ipv6Net { addr, ..range }).network() != range.addr {
            return None;
        }
        u16::try_from(offset).ok()?.try_into().ok()
    }
}

#[derive(Debug, ThisError, PartialEq, Eq)]
pub enum ResolverError {
    #[error(transparent)]
    Parse(#[from] AddrParseError),
    #[error("resolver {0} is not a public unicast address, and VMs may only reach public ones")]
    NotPublic(Ipv4Addr),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
#[display("{_0}")]
pub struct Resolver(Ipv4Addr);

impl FromStr for Resolver {
    type Err = ResolverError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let addr: Ipv4Addr = s.parse()?;
        let special = addr.is_unspecified()
            || addr.is_loopback()
            || addr.is_multicast()
            || addr.is_broadcast();
        let non_public = NON_PUBLIC
            .iter()
            .filter_map(
                |range| match range.parse().expect("the non-public ranges parse") {
                    IpNet::V4(net) => Some(net),
                    IpNet::V6(_) => None,
                },
            )
            .any(|range: Ipv4Net| Ipv4Net { addr, ..range }.network() == range.network());
        if special || non_public {
            return Err(ResolverError::NotPublic(addr));
        }
        Ok(Self(addr))
    }
}

impl Default for Resolver {
    fn default() -> Self {
        Self(Ipv4Addr::new(1, 1, 1, 1))
    }
}

impl Resolver {
    pub fn addr(self) -> Ipv4Addr {
        self.0
    }
}

/// Masquerade IPv4 from `src` leaving through `out`.
struct Masquerade<'a> {
    src: Ipv4Net,
    out: &'a IfName,
}

impl Masquerade<'_> {
    fn chain(&self) -> Chain {
        Chain {
            name: "postrouting".to_owned(),
            kind: ChainType::Nat,
            hook: Hook::Postrouting,
            priority: SRCNAT_PRIORITY,
            policy: Policy::Accept,
            rules: vec![Rule {
                matches: vec![
                    Match::Ipv4Saddr(self.src),
                    Match::Oifname(Iface::Named(self.out.clone())),
                ],
                action: Action::Masquerade,
            }],
        }
    }
}

/// A filter chain on `hook`.
struct Filter {
    hook: Hook,
    policy: Policy,
    rules: Vec<Rule>,
}

impl Filter {
    fn chain(self) -> Chain {
        let name: &'static str = self.hook.into();
        Chain {
            name: name.to_owned(),
            kind: ChainType::Filter,
            hook: self.hook,
            priority: FILTER_PRIORITY,
            policy: self.policy,
            rules: self.rules,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{NetId, NodePrefix, Resolver, ResolverError};
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use test_strategy::proptest;

    fn net_id(id: u16) -> NetId {
        id.try_into().unwrap()
    }

    fn prefix() -> NodePrefix {
        "2001:db8::/64".parse().unwrap()
    }

    #[proptest]
    fn net_ids_past_the_transit_range_are_refused(id: u16) {
        prop_assert_eq!(NetId::try_from(id).is_ok(), u32::from(id) < 16_384);
    }

    #[proptest]
    fn distinct_net_ids_get_disjoint_transit_subnets(
        #[strategy(0u16..16_384)] a: u16,
        #[strategy(0u16..16_384)] b: u16,
    ) {
        prop_assume!(a != b);
        let (a, b) = (net_id(a), net_id(b));
        prop_assert_ne!(a.host_addr().network(), b.host_addr().network());
    }

    #[proptest]
    fn host_and_uplink_share_a_subnet_and_avoid_its_edges(#[strategy(0u16..16_384)] id: u16) {
        let id = net_id(id);
        let (host, uplink) = (id.host_addr(), id.uplink_addr());
        let network = u32::from(host.network());
        let transit = u32::from(NetId::transit_range().addr);
        prop_assert_eq!(host.network(), uplink.network());
        prop_assert_eq!(network >> 16, transit >> 16);
        for addr in [host.addr, uplink.addr] {
            prop_assert!(u32::from(addr) != network && u32::from(addr) != network + 3);
        }
    }

    #[proptest]
    fn an_uplink_address_maps_back_to_its_net_id(#[strategy(0u16..16_384)] id: u16) {
        let id = net_id(id);
        prop_assert_eq!(NetId::from_uplink_addr(id.uplink_addr().addr), Some(id));
    }

    #[proptest]
    fn only_uplink_addresses_map_to_a_net_id(#[strategy(any::<u32>())] addr: u32) {
        let addr = Ipv4Addr::from(addr);
        if let Some(id) = NetId::from_uplink_addr(addr) {
            prop_assert_eq!(id.uplink_addr().addr, addr);
        }
    }

    #[proptest]
    fn a_guest_address_maps_back_to_its_net_id(#[strategy(0u16..16_384)] id: u16) {
        prop_assert_eq!(
            prefix().guest_net_id(prefix().guest(net_id(id))),
            Some(net_id(id))
        );
    }

    #[proptest]
    fn only_guest_addresses_map_to_a_net_id(
        #[strategy(0u128..(1 << 17))] offset: u128,
        inside: bool,
    ) {
        let range = u128::from(prefix().vm_range().addr);
        let base = if inside { range } else { range ^ (1 << 48) };
        prop_assert_eq!(
            prefix().guest_net_id(Ipv6Addr::from(base + offset)),
            (inside && offset < 16_384).then(|| net_id(u16::try_from(offset).unwrap()))
        );
    }

    #[proptest]
    fn a_guest_address_sits_in_the_vm_range_and_ends_in_its_net_id(
        #[strategy(0u16..16_384)] id: u16,
    ) {
        let guest = u128::from(prefix().guest(net_id(id)));
        let range = u128::from(prefix().vm_range().addr);
        prop_assert_eq!(guest >> 48, range >> 48);
        prop_assert_eq!(guest & 0xffff_ffff_ffff, u128::from(id));
    }

    #[rstest]
    #[case::first(
        0,
        "vm-veth-0",
        Ipv4Addr::new(10, 200, 0, 1),
        Ipv4Addr::new(10, 200, 0, 2),
        "2001:db8::1:0:0:0"
    )]
    #[case::second(
        1,
        "vm-veth-1",
        Ipv4Addr::new(10, 200, 0, 5),
        Ipv4Addr::new(10, 200, 0, 6),
        "2001:db8::1:0:0:1"
    )]
    #[case::next_octet(
        64,
        "vm-veth-64",
        Ipv4Addr::new(10, 200, 1, 1),
        Ipv4Addr::new(10, 200, 1, 2),
        "2001:db8::1:0:0:40"
    )]
    #[case::last(
        16_383,
        "vm-veth-16383",
        Ipv4Addr::new(10, 200, 255, 253),
        Ipv4Addr::new(10, 200, 255, 254),
        "2001:db8::1:0:0:3fff"
    )]
    fn the_cookbook_table_holds(
        #[case] id: u16,
        #[case] veth: &str,
        #[case] host: Ipv4Addr,
        #[case] uplink: Ipv4Addr,
        #[case] guest: Ipv6Addr,
    ) {
        let id = net_id(id);
        assert_eq!(
            (
                id.host_veth().to_string(),
                id.host_addr().addr,
                id.uplink_addr().addr,
                prefix().guest(id),
            ),
            (veth.to_owned(), host, uplink, guest)
        );
    }

    #[rstest]
    #[case::host_bits_cleared("2001:db8::5/64", Some("2001:db8::/64"))]
    #[case::shorter("2001:db8::/48", Some("2001:db8::/48"))]
    #[case::too_long("2001:db8::/65", None)]
    #[case::ipv4("10.0.0.0/8", None)]
    #[case::no_prefix("2001:db8::", None)]
    #[case::unique_local("fd12:3456:789a::/64", None)]
    #[case::covering_unique_local("fc00::/6", None)]
    #[case::six_to_four("2002:c000:204::/48", None)]
    fn node_prefixes_are_ipv6_and_at_most_64_bits(#[case] s: &str, #[case] parsed: Option<&str>) {
        assert_eq!(
            s.parse::<NodePrefix>().ok().map(|p| p.to_string()),
            parsed.map(str::to_owned)
        );
    }

    #[rstest]
    #[case::public("1.1.1.1", Some("1.1.1.1"))]
    #[case::public_next_to_a_private_range("11.0.0.1", Some("11.0.0.1"))]
    #[case::private("10.0.0.53", None)]
    #[case::private_top_of_range("172.31.255.255", None)]
    #[case::home("192.168.1.1", None)]
    #[case::cgnat("100.64.0.1", None)]
    #[case::link_local("169.254.169.254", None)]
    #[case::loopback("127.0.0.53", None)]
    #[case::unspecified("0.0.0.0", None)]
    #[case::multicast("224.0.0.251", None)]
    #[case::broadcast("255.255.255.255", None)]
    #[case::ipv6("2606:4700:4700::1111", None)]
    fn only_public_ipv4_resolvers_are_accepted(#[case] s: &str, #[case] parsed: Option<&str>) {
        assert_eq!(
            s.parse::<Resolver>().ok().map(|r| r.to_string()),
            parsed.map(str::to_owned)
        );
    }

    #[proptest]
    fn every_address_in_a_vm_unreachable_range_is_refused_as_a_resolver(
        #[strategy(prop_oneof![
            (0u32..1 << 24).prop_map(|host| (10u32 << 24) | host),
            (0u32..1 << 20).prop_map(|host| ((172u32 << 24) | (16 << 16)) | host),
            (0u32..1 << 16).prop_map(|host| ((192u32 << 24) | (168 << 16)) | host),
            (0u32..1 << 22).prop_map(|host| ((100u32 << 24) | (64 << 16)) | host),
            (0u32..1 << 16).prop_map(|host| ((169u32 << 24) | (254 << 16)) | host),
        ])]
        addr: u32,
    ) {
        let addr = Ipv4Addr::from(addr);
        prop_assert_eq!(
            addr.to_string().parse::<Resolver>(),
            Err(ResolverError::NotPublic(addr))
        );
    }
}
