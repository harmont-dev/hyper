// SPDX-License-Identifier: MIT

use super::{
    IfIndex, IfName, IpNet, Ipv4Net, Ipv6Net, PrefixError, RequestError, Rtnl, ZeroIfIndex,
};
use derive_more::Constructor;
use netlink_packet_core::{NLM_F_CREATE, NLM_F_EXCL};
use netlink_packet_route::address::{AddressAttribute, AddressHeaderFlags, AddressMessage};
use netlink_packet_route::link::{
    AfSpecInet6, AfSpecUnspec, In6AddrGenMode, LinkAttribute, LinkFlags, LinkMessage,
};
use netlink_packet_route::neighbour::{
    NeighbourAddress, NeighbourAttribute, NeighbourFlags, NeighbourMessage, NeighbourState,
};
use netlink_packet_route::{AddressFamily, RouteNetlinkMessage};
use nix::errno::Errno;
use std::net::{IpAddr, Ipv6Addr};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum LinkError {
    #[error("link {0} already exists")]
    Exists(IfName),
    #[error(transparent)]
    Request(#[from] RequestError),
    #[error("unexpected rtnetlink reply: {0:?}")]
    UnexpectedReply(Box<RouteNetlinkMessage>),
    #[error(transparent)]
    Index(#[from] ZeroIfIndex),
    #[error("link {0} vanished after it was created")]
    Vanished(IfName),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DuplicateAddrDetection {
    Enabled,
    Disabled,
}

#[derive(Debug, ThisError)]
pub enum AddrError {
    #[error("address {0} already exists")]
    Exists(IpNet),
    #[error("address {0}: {1}")]
    Request(IpNet, #[source] RequestError),
}

#[derive(Debug, ThisError)]
pub enum AddrListError {
    #[error("listing addresses: {0}")]
    Request(#[from] RequestError),
    #[error("listing addresses: {0}")]
    Prefix(#[from] PrefixError),
}

#[derive(Debug, ThisError)]
#[error("proxy neighbour {0}: {1}")]
pub struct NeighError(Ipv6Addr, #[source] RequestError);

#[derive(Constructor)]
pub struct Link<'r> {
    rtnl: &'r Rtnl,
    index: IfIndex,
}

impl Link<'_> {
    /// The kernel's index for this link in its namespace.
    pub fn index(&self) -> IfIndex {
        self.index
    }

    /// Bring the link up.
    pub fn set_up(&self) -> Result<(), LinkError> {
        let mut request = self.message();
        request.header.flags = LinkFlags::Up;
        request.header.change_mask = LinkFlags::Up;
        self.rtnl.ack(RouteNetlinkMessage::SetLink(request), 0)?;
        Ok(())
    }

    /// Stop the kernel from generating IPv6 addresses, including the link-local one.
    pub fn disable_addr_gen(&self) -> Result<(), LinkError> {
        let mut request = self.message();
        request.attributes = vec![LinkAttribute::AfSpecUnspec(vec![AfSpecUnspec::Inet6(
            vec![AfSpecInet6::AddrGenMode(In6AddrGenMode::None)],
        )])];
        self.rtnl.ack(RouteNetlinkMessage::SetLink(request), 0)?;
        Ok(())
    }

    /// Delete the link; a link that is already gone is `Ok`.
    pub fn delete(self) -> Result<(), LinkError> {
        match self
            .rtnl
            .ack(RouteNetlinkMessage::DelLink(self.message()), 0)
        {
            Ok(()) | Err(RequestError::Kernel(Errno::ENODEV)) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// Add `addr`, failing if it already exists.
    pub fn add_addr(&self, addr: IpNet, dad: DuplicateAddrDetection) -> Result<(), AddrError> {
        let mut request = AddressMessage::default();
        request.header.index = self.index.get();
        request.header.prefix_len = addr.prefix_len();
        request.header.family = match addr {
            IpNet::V4(_) => AddressFamily::Inet,
            IpNet::V6(_) => AddressFamily::Inet6,
        };
        request.header.flags = match dad {
            DuplicateAddrDetection::Enabled => AddressHeaderFlags::empty(),
            DuplicateAddrDetection::Disabled => AddressHeaderFlags::Nodad,
        };
        request.attributes = match addr {
            IpNet::V4(_) => vec![
                AddressAttribute::Local(addr.addr()),
                AddressAttribute::Address(addr.addr()),
            ],
            IpNet::V6(_) => vec![AddressAttribute::Address(addr.addr())],
        };

        match self.rtnl.ack(
            RouteNetlinkMessage::NewAddress(request),
            NLM_F_CREATE | NLM_F_EXCL,
        ) {
            Ok(()) => Ok(()),
            Err(RequestError::Kernel(Errno::EEXIST)) => Err(AddrError::Exists(addr)),
            Err(e) => Err(AddrError::Request(addr, e)),
        }
    }

    /// Every address on the link.
    pub fn addrs(&self) -> Result<Vec<IpNet>, AddrListError> {
        let mut request = AddressMessage::default();
        request.header.index = self.index.get();

        self.rtnl
            .dump(RouteNetlinkMessage::GetAddress(request))?
            .into_iter()
            .filter_map(|reply| match reply {
                RouteNetlinkMessage::NewAddress(addr) if addr.header.index == self.index.get() => {
                    Some(addr)
                }
                _ => None,
            })
            .filter_map(|addr| {
                let len = addr.header.prefix_len;
                addr.attributes
                    .into_iter()
                    .find_map(|attr| match attr {
                        AddressAttribute::Address(ip) => Some(ip),
                        _ => None,
                    })
                    .map(|ip| Self::net(ip, len))
            })
            .collect()
    }

    /// Answer neighbour solicitations for `addr` on this link; adding it again is `Ok`.
    pub fn add_proxy_neigh(&self, addr: Ipv6Addr) -> Result<(), NeighError> {
        self.rtnl
            .ack(
                RouteNetlinkMessage::NewNeighbour(self.proxy_neigh(addr)),
                NLM_F_CREATE,
            )
            .map_err(|e| NeighError(addr, e))
    }

    /// The addresses this link answers neighbour solicitations for, as `ip -6 neigh show proxy dev <link>` lists them ([ip-neighbour(8)](https://man7.org/linux/man-pages/man8/ip-neighbour.8.html)).
    pub fn proxy_neighs(&self) -> Result<Vec<Ipv6Addr>, RequestError> {
        let mut request = NeighbourMessage::default();
        request.header.family = AddressFamily::Inet6;
        request.header.ifindex = self.index.get();
        request.header.flags = NeighbourFlags::Proxy;

        Ok(self
            .rtnl
            .dump(RouteNetlinkMessage::GetNeighbour(request))?
            .into_iter()
            .filter_map(|reply| match reply {
                RouteNetlinkMessage::NewNeighbour(neigh)
                    if neigh.header.ifindex == self.index.get()
                        && neigh.header.flags.contains(NeighbourFlags::Proxy) =>
                {
                    neigh.attributes.into_iter().find_map(|attr| match attr {
                        NeighbourAttribute::Destination(NeighbourAddress::Inet6(addr)) => {
                            Some(addr)
                        }
                        _ => None,
                    })
                }
                _ => None,
            })
            .collect())
    }

    /// Stop answering neighbour solicitations for `addr`; a missing entry is `Ok`.
    pub fn delete_proxy_neigh(&self, addr: Ipv6Addr) -> Result<(), NeighError> {
        match self
            .rtnl
            .ack(RouteNetlinkMessage::DelNeighbour(self.proxy_neigh(addr)), 0)
        {
            Ok(()) | Err(RequestError::Kernel(Errno::ENOENT)) => Ok(()),
            Err(e) => Err(NeighError(addr, e)),
        }
    }

    fn net(addr: IpAddr, len: u8) -> Result<IpNet, AddrListError> {
        Ok(match addr {
            IpAddr::V4(addr) => IpNet::V4(Ipv4Net {
                addr,
                prefix: len.try_into()?,
            }),
            IpAddr::V6(addr) => IpNet::V6(Ipv6Net {
                addr,
                prefix: len.try_into()?,
            }),
        })
    }

    fn message(&self) -> LinkMessage {
        let mut message = LinkMessage::default();
        message.header.index = self.index.get();
        message
    }

    fn proxy_neigh(&self, addr: Ipv6Addr) -> NeighbourMessage {
        let mut message = NeighbourMessage::default();
        message.header.family = AddressFamily::Inet6;
        message.header.ifindex = self.index.get();
        message.header.flags = NeighbourFlags::Proxy;
        message.header.state = NeighbourState::Permanent;
        message.attributes = vec![NeighbourAttribute::Destination(NeighbourAddress::Inet6(
            addr,
        ))];
        message
    }
}

#[cfg(test)]
mod tests {
    use super::{AddrError, DuplicateAddrDetection};
    use crate::net::netns::NetNs;
    use crate::net::{IfName, IpNet};
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use std::fs;
    use std::net::{IpAddr, Ipv6Addr};

    struct ScratchNs(Option<NetNs>);

    impl ScratchNs {
        fn new(test: &str) -> Option<Self> {
            if !nix::unistd::geteuid().is_root() {
                eprintln!("SKIP {test}: needs root to create a network namespace");
                return None;
            }
            let name = format!("hyper-test-{}-{test}", std::process::id());
            Some(Self(Some(
                NetNs::create(name.as_str().try_into().unwrap()).unwrap(),
            )))
        }

        fn get(&self) -> &NetNs {
            self.0.as_ref().expect("the namespace lives until drop")
        }
    }

    impl Drop for ScratchNs {
        fn drop(&mut self) {
            if let Some(ns) = self.0.take() {
                let _ = ns.remove();
            }
        }
    }

    struct Pair {
        host: ScratchNs,
        peer: ScratchNs,
    }

    impl Pair {
        const HOST: &str = "hv0";
        const PEER: &str = "hp0";

        fn new(test: &str) -> Option<Self> {
            let (Some(host), Some(peer)) = (
                ScratchNs::new(&format!("{test}-host")),
                ScratchNs::new(&format!("{test}-peer")),
            ) else {
                return None;
            };
            host.get()
                .rtnl()
                .unwrap()
                .create_veth(&Self::host(), &Self::peer(), peer.get())
                .unwrap();
            Some(Self { host, peer })
        }

        fn host() -> IfName {
            Self::HOST.parse().unwrap()
        }

        fn peer() -> IfName {
            Self::PEER.parse().unwrap()
        }
    }

    struct Inet6Addr {
        addr: Ipv6Addr,
        tentative: bool,
    }

    impl Inet6Addr {
        const IFA_F_TENTATIVE: u32 = 0x40;

        fn list(ns: &NetNs) -> Vec<Self> {
            ns.scoped(|| fs::read_to_string("/proc/thread-self/net/if_inet6"))
                .unwrap()
                .unwrap_or_default()
                .lines()
                .map(|line| {
                    let fields: Vec<&str> = line.split_whitespace().collect();
                    let flags = u32::from_str_radix(fields[4], 16).unwrap();
                    Self {
                        addr: u128::from_str_radix(fields[0], 16).unwrap().into(),
                        tentative: flags & Self::IFA_F_TENTATIVE != 0,
                    }
                })
                .collect()
        }
    }

    #[rstest]
    fn deleting_a_veth_end_removes_both_ends_as_root() {
        let Some(pair) = Pair::new("delete") else {
            return;
        };
        let host_rtnl = pair.host.get().rtnl().unwrap();
        let peer_rtnl = pair.peer.get().rtnl().unwrap();

        host_rtnl
            .link(&Pair::host())
            .unwrap()
            .unwrap()
            .delete()
            .unwrap();

        assert_eq!(
            [
                host_rtnl.link(&Pair::host()).unwrap().is_some(),
                peer_rtnl.link(&Pair::peer()).unwrap().is_some(),
            ],
            [false, false]
        );
    }

    #[rstest]
    fn disabling_addr_gen_sets_the_mode_to_none_as_root() {
        const IN6_ADDR_GEN_MODE_NONE: &str = "1";
        let Some(pair) = Pair::new("addr-gen") else {
            return;
        };
        let rtnl = pair.host.get().rtnl().unwrap();
        let link = rtnl.link(&Pair::host()).unwrap().unwrap();
        let mode = || {
            pair.host
                .get()
                .scoped(|| {
                    fs::read_to_string(format!(
                        "/proc/sys/net/ipv6/conf/{}/addr_gen_mode",
                        Pair::HOST
                    ))
                })
                .unwrap()
                .unwrap()
                .trim()
                .to_owned()
        };
        let before = mode();

        link.disable_addr_gen().unwrap();

        assert_ne!(before, IN6_ADDR_GEN_MODE_NONE);
        assert_eq!(mode(), IN6_ADDR_GEN_MODE_NONE);
    }

    #[rstest]
    #[case::dad("dad-on", DuplicateAddrDetection::Enabled, true)]
    #[case::no_dad("dad-off", DuplicateAddrDetection::Disabled, false)]
    fn only_dad_addresses_start_tentative_as_root(
        #[case] test: &str,
        #[case] dad: DuplicateAddrDetection,
        #[case] tentative: bool,
    ) {
        let Some(pair) = Pair::new(test) else {
            return;
        };
        let rtnl = pair.host.get().rtnl().unwrap();
        let link = rtnl.link(&Pair::host()).unwrap().unwrap();
        let addr: IpNet = "2001:db8::1:0:0:5/128".parse().unwrap();

        link.add_addr(addr, dad).unwrap();

        let added: Vec<bool> = Inet6Addr::list(pair.host.get())
            .iter()
            .filter(|a| IpAddr::V6(a.addr) == addr.addr())
            .map(|a| a.tentative)
            .collect();
        assert_eq!(added, [tentative]);
    }

    #[rstest]
    #[case::v4("addr-v4", "10.200.0.1/30")]
    #[case::v6("addr-v6", "2001:db8::1/64")]
    fn adding_an_address_twice_is_exists_as_root(#[case] test: &str, #[case] addr: &str) {
        let Some(pair) = Pair::new(test) else {
            return;
        };
        let rtnl = pair.host.get().rtnl().unwrap();
        let link = rtnl.link(&Pair::host()).unwrap().unwrap();
        let addr: IpNet = addr.parse().unwrap();

        link.add_addr(addr, DuplicateAddrDetection::Disabled)
            .unwrap();
        let again = link.add_addr(addr, DuplicateAddrDetection::Disabled);

        assert!(matches!(again, Err(AddrError::Exists(a)) if a == addr));
    }

    #[rstest]
    fn a_link_lists_exactly_its_own_addresses_as_root() {
        let Some(pair) = Pair::new("addrs") else {
            return;
        };
        let rtnl = pair.host.get().rtnl().unwrap();
        let link = rtnl.link(&Pair::host()).unwrap().unwrap();
        let lo = rtnl.link(&"lo".parse().unwrap()).unwrap().unwrap();
        let added: Vec<IpNet> = ["10.200.0.1/30", "2001:db8::1:0:0:5/128"]
            .into_iter()
            .map(|addr| addr.parse().unwrap())
            .collect();
        lo.add_addr(
            "10.9.0.1/8".parse().unwrap(),
            DuplicateAddrDetection::Disabled,
        )
        .unwrap();

        for addr in &added {
            link.add_addr(*addr, DuplicateAddrDetection::Disabled)
                .unwrap();
        }

        let mut listed = link.addrs().unwrap();
        listed.sort_by_key(|net| (net.addr(), net.prefix_len()));
        assert_eq!(listed, added);
    }

    #[rstest]
    fn proxy_neighbours_add_list_and_delete_idempotently_as_root() {
        let Some(pair) = Pair::new("proxy-neigh") else {
            return;
        };
        let rtnl = pair.host.get().rtnl().unwrap();
        let link = rtnl.link(&Pair::host()).unwrap().unwrap();
        let lo = rtnl.link(&"lo".parse().unwrap()).unwrap().unwrap();
        let addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 1, 0, 0, 5);
        let other = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 1, 0, 0, 6);
        lo.add_proxy_neigh(Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 1, 0, 0, 7))
            .unwrap();

        link.add_proxy_neigh(addr).unwrap();
        link.add_proxy_neigh(addr).unwrap();
        link.add_proxy_neigh(other).unwrap();
        let mut listed = link.proxy_neighs().unwrap();
        listed.sort();
        assert_eq!(listed, vec![addr, other]);

        link.delete_proxy_neigh(addr).unwrap();
        link.delete_proxy_neigh(addr).unwrap();
        assert_eq!(link.proxy_neighs().unwrap(), vec![other]);
    }
}
