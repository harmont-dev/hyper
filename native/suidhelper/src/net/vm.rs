// SPDX-License-Identifier: MIT
//! One VM's network namespace: built by `vm_launch`, removed by `vm_teardown`.

use super::firewall::Firewall;
use super::{Filter, Masquerade, NetId, DSTNAT_PRIORITY, FIREWALL_TABLE, NON_PUBLIC, TABLE};
use crate::config::Net;
use hyperrs_firecracker::VmId;
use hyperrs_fs::file::ValidationError;
use hyperrs_fs::path::{StrictComponent, StrictComponentBuf};
use hyperrs_linux::net::link::{
    AddrError, AddrListError, DuplicateAddrDetection, Link, LinkError, NeighError,
};
use hyperrs_linux::net::netns::{
    CreateError, EnterError, ForwardingError, NetNs, OpenError, RemoveError, RtnlError, TapError,
};
use hyperrs_linux::net::nft::{
    Action, Chain, ChainType, CtState, Family, Hook, Icmpv6Type, Iface, L4Proto, Match, Nft,
    NftError, Policy, Rule, Table,
};
use hyperrs_linux::net::route::{Route, RouteError};
use hyperrs_linux::net::{IfIndex, IfName, IpNet, Ipv4Net, Ipv6Net, Prefix, Rtnl, RtnlOpenError};
use hyperrs_process::privilege::Root;
use nix::errno::Errno;
use nix::unistd::{Gid, Uid};
use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::LazyLock;
use thiserror::Error as ThisError;

static LO: LazyLock<IfName> = LazyLock::new(|| "lo".parse().expect("lo is an interface name"));
static UPLINK: LazyLock<IfName> =
    LazyLock::new(|| "uplink".parse().expect("uplink is an interface name"));
static TAP: LazyLock<IfName> = LazyLock::new(|| "tap0".parse().expect("tap0 is an interface name"));

const TAP_ADDR: Ipv4Addr = Ipv4Addr::new(172, 16, 0, 1);
const GUEST_ADDR: Ipv4Addr = Ipv4Addr::new(172, 16, 0, 2);
const GUEST_SUBNET_PREFIX: u8 = 30;
const DNS_PORT: u16 = 53;
const HOST_LINK_LOCAL: Ipv6Addr = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
const UPLINK_LINK_LOCAL: Ipv6Addr = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 2);
const TAP_LINK_LOCAL: Ipv6Addr = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
const LINK_LOCAL_PREFIX: u8 = 64;

#[derive(Debug, ThisError)]
pub enum VmNetError {
    #[error("creating the VM's network namespace: {0}")]
    Create(#[from] CreateError),
    #[error("opening the VM's network namespace: {0}")]
    Open(#[from] OpenError),
    #[error("removing the VM's network namespace: {0}")]
    Remove(#[from] RemoveError),
    #[error(transparent)]
    HostRtnl(#[from] RtnlOpenError),
    #[error(transparent)]
    NsRtnl(#[from] RtnlError),
    #[error(transparent)]
    Enter(#[from] EnterError),
    #[error(transparent)]
    Link(#[from] LinkError),
    #[error("link {0} is missing")]
    MissingLink(IfName),
    #[error(transparent)]
    Addr(#[from] AddrError),
    #[error(transparent)]
    AddrList(#[from] AddrListError),
    #[error(transparent)]
    Route(#[from] RouteError),
    #[error(transparent)]
    Neigh(#[from] NeighError),
    #[error(transparent)]
    Tap(#[from] TapError),
    #[error(transparent)]
    Forwarding(#[from] ForwardingError),
    #[error("VM firewall: {0}")]
    Nft(#[from] NftError),
    #[error("VM {0} has no network namespace")]
    NotFound(VmId),
}

/// The network of VM `id`.
pub struct VmNet<'a> {
    pub id: &'a VmId,
}

impl VmNet<'_> {
    /// The VM's namespace, `hyper-<id>`.
    pub fn netns_name(&self) -> StrictComponentBuf {
        let name = format!("hyper-{}", self.id.as_os_str().to_string_lossy());
        let component: &StrictComponent = name
            .as_str()
            .try_into()
            .expect("hyper-<vm id> is a strict path component");
        component.to_owned()
    }

    /// Build the VM's namespace, with `tap0` owned by `uid`:`gid` for Firecracker.
    pub fn prepare(
        &self,
        root: &Root<'_>,
        net_id: NetId,
        net: &Net,
        nft: &Nft,
        owner: (Uid, Gid),
        firewall: &Firewall,
    ) -> Result<NetNs, VmNetError> {
        let (uid, gid) = owner;
        let ns = NetNs::create(&self.netns_name())?;
        let host = Rtnl::open()?;
        let inner = ns.rtnl()?;
        let guest = net.ipv6_prefix().guest(net_id);

        let veth = host.create_veth(&net_id.host_veth(), &UPLINK, &ns)?;
        veth.disable_addr_gen()?;
        veth.add_addr(
            IpNet::V4(net_id.host_addr()),
            DuplicateAddrDetection::Disabled,
        )?;
        veth.add_addr(
            IpNet::V6(Self::link_local(HOST_LINK_LOCAL)),
            DuplicateAddrDetection::Disabled,
        )?;
        veth.set_up()?;

        Self::existing(&inner, &LO)?.set_up()?;
        let uplink = Self::existing(&inner, &UPLINK)?;
        uplink.disable_addr_gen()?;
        uplink.add_addr(
            IpNet::V4(net_id.uplink_addr()),
            DuplicateAddrDetection::Disabled,
        )?;
        uplink.add_addr(
            IpNet::V6(Self::link_local(UPLINK_LINK_LOCAL)),
            DuplicateAddrDetection::Disabled,
        )?;
        uplink.set_up()?;

        ns.create_tap(&TAP, uid, gid)?;
        let tap = Self::existing(&inner, &TAP)?;
        tap.disable_addr_gen()?;
        tap.add_addr(
            IpNet::V4(Ipv4Net {
                addr: TAP_ADDR,
                prefix: Self::prefix(GUEST_SUBNET_PREFIX),
            }),
            DuplicateAddrDetection::Disabled,
        )?;
        tap.add_addr(
            IpNet::V6(Self::link_local(TAP_LINK_LOCAL)),
            DuplicateAddrDetection::Disabled,
        )?;
        tap.set_up()?;

        inner.add_route(&Route::V4 {
            dst: Ipv4Net {
                addr: Ipv4Addr::UNSPECIFIED,
                prefix: Self::prefix(0),
            },
            via: Some(net_id.host_addr().addr),
            dev: uplink.index(),
        })?;
        inner.add_route(&Route::V6 {
            dst: Ipv6Net {
                addr: Ipv6Addr::UNSPECIFIED,
                prefix: Self::prefix(0),
            },
            via: Some(HOST_LINK_LOCAL),
            dev: uplink.index(),
        })?;
        inner.add_route(&Self::guest_route(guest, None, tap.index()))?;
        host.add_route(&Self::guest_route(
            guest,
            Some(UPLINK_LINK_LOCAL),
            veth.index(),
        ))?;

        Self::existing(&host, net.uplink())?.add_proxy_neigh(guest)?;

        ns.enable_forwarding()?;
        ns.scoped(|| nft.replace_table(root, &Self::table(guest, uid, net.resolver().addr())))??;
        ns.scoped(|| nft.replace_table(root, &Self::firewall_table(firewall)))??;

        Ok(ns)
    }

    /// Replace the running VM's port policy with `firewall`.
    pub fn set_firewall(
        &self,
        root: &Root<'_>,
        nft: &Nft,
        firewall: &Firewall,
    ) -> Result<(), VmNetError> {
        let ns = match NetNs::open(&self.netns_name()) {
            Ok(ns) => ns,
            Err(OpenError::Open(ValidationError::Open(Errno::ENOENT)) | OpenError::NotNetNs(_)) => {
                return Err(VmNetError::NotFound(self.id.clone()))
            }
            Err(e) => return Err(e.into()),
        };
        ns.scoped(|| nft.replace_table(root, &Self::firewall_table(firewall)))??;
        Ok(())
    }

    /// Remove everything [`VmNet::prepare`] built; whatever is already gone is skipped.
    ///
    /// Without `net` there is no proxy NDP entry to find, but the veth pair and the
    /// namespace are still removed.
    pub fn teardown(&self, net: Option<&Net>) -> Result<(), VmNetError> {
        if let Some(net_id) = self.built_net_id()? {
            self.unlink(net_id, net)?;
        }
        NetNs::delete(&self.netns_name())?;
        Ok(())
    }

    fn unlink(&self, net_id: NetId, net: Option<&Net>) -> Result<(), VmNetError> {
        let host = Rtnl::open()?;

        if let Some(net) = net {
            if let Some(uplink) = host.link(net.uplink())? {
                uplink.delete_proxy_neigh(net.ipv6_prefix().guest(net_id))?;
            }
        }
        if let Some(veth) = host.link(&net_id.host_veth())? {
            veth.delete()?;
        }
        Ok(())
    }

    fn built_net_id(&self) -> Result<Option<NetId>, VmNetError> {
        let ns = match NetNs::open(&self.netns_name()) {
            Ok(ns) => ns,
            Err(OpenError::Open(ValidationError::Open(Errno::ENOENT)) | OpenError::NotNetNs(_)) => {
                return Ok(None)
            }
            Err(e) => return Err(e.into()),
        };
        let inner = ns.rtnl()?;
        let Some(uplink) = inner.link(&UPLINK)? else {
            return Ok(None);
        };
        Ok(uplink.addrs()?.into_iter().find_map(|addr| match addr {
            IpNet::V4(addr) => NetId::from_uplink_addr(addr.addr),
            IpNet::V6(_) => None,
        }))
    }

    /// Only the guest's own addresses leave `tap0`, and the jailed Firecracker (`uid`)
    /// sends nothing from the namespace itself.
    fn table(guest: Ipv6Addr, uid: Uid, resolver: Ipv4Addr) -> Table {
        let guest_v4 = Ipv4Net {
            addr: GUEST_ADDR,
            prefix: Self::prefix(32),
        };
        let from_guest = |saddr| Rule {
            matches: vec![Match::Iifname(Iface::Named(TAP.clone())), saddr],
            action: Action::Accept,
        };
        Table {
            family: Family::Inet,
            name: TABLE.to_owned(),
            chains: vec![
                Self::dns_chain(resolver),
                Masquerade {
                    src: guest_v4,
                    out: &UPLINK,
                }
                .chain(),
                Filter {
                    hook: Hook::Input,
                    policy: Policy::Drop,
                    rules: [
                        Match::Iifname(Iface::Named(LO.clone())),
                        Match::CtState(CtState::Established),
                        Match::CtState(CtState::Related),
                        Match::Icmpv6Type(Icmpv6Type::NeighborSolicit),
                        Match::Icmpv6Type(Icmpv6Type::NeighborAdvert),
                    ]
                    .into_iter()
                    .map(|allowed| Rule {
                        matches: vec![allowed],
                        action: Action::Accept,
                    })
                    .collect(),
                }
                .chain(),
                Filter {
                    hook: Hook::Forward,
                    policy: Policy::Drop,
                    rules: NON_PUBLIC
                        .iter()
                        .map(|range| Rule {
                            matches: vec![
                                Match::Iifname(Iface::Named(TAP.clone())),
                                match range.parse().expect("the non-public ranges parse") {
                                    IpNet::V4(net) => Match::Ipv4Daddr(net),
                                    IpNet::V6(net) => Match::Ipv6Daddr(net),
                                },
                            ],
                            action: Action::Drop,
                        })
                        .chain([
                            from_guest(Match::Ipv4Saddr(guest_v4)),
                            from_guest(Match::Ipv6Saddr(Ipv6Net {
                                addr: guest,
                                prefix: Self::prefix(128),
                            })),
                            Rule {
                                matches: vec![
                                    Match::Iifname(Iface::Named(UPLINK.clone())),
                                    Match::Oifname(Iface::Named(TAP.clone())),
                                ],
                                action: Action::Accept,
                            },
                        ])
                        .collect(),
                }
                .chain(),
                Filter {
                    hook: Hook::Output,
                    policy: Policy::Accept,
                    rules: vec![Rule {
                        matches: vec![Match::Skuid(uid)],
                        action: Action::Drop,
                    }],
                }
                .chain(),
            ],
        }
    }

    fn dns_chain(resolver: Ipv4Addr) -> Chain {
        let to_gateway = |proto| Rule {
            matches: vec![
                Match::Iifname(Iface::Named(TAP.clone())),
                Match::Ipv4Daddr(Ipv4Net {
                    addr: TAP_ADDR,
                    prefix: Self::prefix(32),
                }),
                Match::Dport(proto, DNS_PORT..=DNS_PORT),
            ],
            action: Action::Dnat(resolver),
        };
        Chain {
            name: "prerouting".to_owned(),
            kind: ChainType::Nat,
            hook: Hook::Prerouting,
            priority: DSTNAT_PRIORITY,
            policy: Policy::Accept,
            rules: vec![to_gateway(L4Proto::Udp), to_gateway(L4Proto::Tcp)],
        }
    }

    /// Inbound, only replies and `firewall`'s open ports reach `tap0`; outbound, its
    /// blocked ports never leave it.
    fn firewall_table(firewall: &Firewall) -> Table {
        let inbound = |extra: Option<Match>, action| Rule {
            matches: [
                Match::Iifname(Iface::Named(UPLINK.clone())),
                Match::Oifname(Iface::Named(TAP.clone())),
            ]
            .into_iter()
            .chain(extra)
            .collect(),
            action,
        };
        let rules = [CtState::Established, CtState::Related]
            .into_iter()
            .map(Match::CtState)
            .chain(firewall.inbound())
            .map(|open| inbound(Some(open), Action::Accept))
            .chain([inbound(None, Action::Drop)])
            .chain(firewall.outbound_blocked().map(|blocked| Rule {
                matches: vec![Match::Iifname(Iface::Named(TAP.clone())), blocked],
                action: Action::Drop,
            }))
            .collect();
        Table {
            family: Family::Inet,
            name: FIREWALL_TABLE.to_owned(),
            chains: vec![Filter {
                hook: Hook::Forward,
                policy: Policy::Accept,
                rules,
            }
            .chain()],
        }
    }

    fn existing<'r>(rtnl: &'r Rtnl, name: &IfName) -> Result<Link<'r>, VmNetError> {
        rtnl.link(name)?
            .ok_or_else(|| VmNetError::MissingLink(name.clone()))
    }

    fn guest_route(guest: Ipv6Addr, via: Option<Ipv6Addr>, dev: IfIndex) -> Route {
        Route::V6 {
            dst: Ipv6Net {
                addr: guest,
                prefix: Self::prefix(128),
            },
            via,
            dev,
        }
    }

    fn link_local(addr: Ipv6Addr) -> Ipv6Net {
        Ipv6Net {
            addr,
            prefix: Self::prefix(LINK_LOCAL_PREFIX),
        }
    }

    fn prefix<const MAX: u8>(len: u8) -> Prefix<MAX> {
        len.try_into()
            .expect("the prefix length is a valid constant")
    }
}

#[cfg(test)]
mod tests {
    use super::{Firewall, VmNet, TAP, UPLINK};
    use hyperrs_linux::net::link::DuplicateAddrDetection;
    use hyperrs_linux::net::netns::NetNs;
    use hyperrs_linux::net::nft::Nft;
    use hyperrs_linux::net::route::Route;
    use hyperrs_linux::net::{IfIndex, IfName, IpNet, Rtnl};
    use hyperrs_process::binary::RootSafeBin;
    use hyperrs_process::privilege::Unprivileged;
    use nix::unistd::{setfsuid, Uid};
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use serde_json::json;
    use socket2::{Domain, Socket, Type};
    use std::net::{Ipv6Addr, SocketAddr, TcpListener};
    use std::path::Path;
    use std::time::Duration;

    const OPEN: u16 = 7071;
    const CLOSED: u16 = 7072;
    const BLOCKED: u16 = 7073;
    const DNS: u16 = 53;
    const NAMESPACE: u16 = 7074;
    const DROPPED_AFTER: Duration = Duration::from_secs(3);
    const FIRECRACKER: u32 = 900_001;
    const GUEST_V6: &str = "2001:db8::1:0:0:5";

    struct ScratchNs(Option<NetNs>);

    impl ScratchNs {
        fn new(test: &str) -> Self {
            let name = format!("hyper-test-{}-{test}", std::process::id());
            Self(Some(
                NetNs::create(name.as_str().try_into().unwrap()).unwrap(),
            ))
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

    #[derive(Debug, Clone, Copy)]
    enum Probe {
        /// From the guest, with this source address.
        Guest(&'static str),
        /// From the VM's namespace itself, as this fsuid.
        Namespace(u32),
        /// From the stand-in host, beyond `uplink`.
        Host,
    }

    /// A guest (`eth0`) on the VM namespace's `tap0`, and a stand-in host on its
    /// `uplink`. Every source address a probe uses is routed both ways, so only the
    /// namespace's table can stop a connection.
    struct Lab {
        guest: ScratchNs,
        vm: ScratchNs,
        host: ScratchNs,
        _listeners: Vec<TcpListener>,
    }

    impl Lab {
        fn new(test: &str) -> Self {
            let guest = ScratchNs::new(&format!("{test}-guest"));
            let vm = ScratchNs::new(&format!("{test}-vm"));
            let host = ScratchNs::new(&format!("{test}-host"));
            let g = guest.get().rtnl().unwrap();
            let v = vm.get().rtnl().unwrap();
            let h = host.get().rtnl().unwrap();

            v.create_veth(&TAP, &Self::name("eth0"), guest.get())
                .unwrap();
            v.create_veth(&UPLINK, &Self::name("wan"), host.get())
                .unwrap();
            Self::up(&v, "lo", &[]);
            let tap = Self::up(&v, "tap0", &["172.16.0.1/30", "fe80::1/64"]);
            let uplink = Self::up(&v, "uplink", &["10.200.0.2/30", "fe80::2/64"]);
            let eth0 = Self::up(
                &g,
                "eth0",
                &[
                    "172.16.0.2/30",
                    "192.0.2.9/32",
                    "2001:db8::1:0:0:5/128",
                    "2001:db8::1:0:0:6/128",
                    "fe80::2/64",
                ],
            );
            let wan = Self::up(
                &h,
                "wan",
                &[
                    "10.200.0.1/30",
                    "198.51.100.1/32",
                    "fe80::1/64",
                    "2001:db8:ffff::1/128",
                ],
            );

            for (rtnl, route) in [
                (&g, Self::route("0.0.0.0/0", Some("172.16.0.1"), eth0)),
                (&g, Self::route("::/0", Some("fe80::1"), eth0)),
                (&v, Self::route("192.0.2.9/32", None, tap)),
                (&v, Self::route("2001:db8:0:0:1::/80", None, tap)),
                (&v, Self::route("::/0", Some("fe80::1"), uplink)),
                (&v, Self::route("0.0.0.0/0", Some("10.200.0.1"), uplink)),
                (&h, Self::route("192.0.2.9/32", Some("10.200.0.2"), wan)),
                (&h, Self::route("2001:db8:0:0:1::/80", Some("fe80::2"), wan)),
            ] {
                rtnl.add_route(&route).unwrap();
            }

            vm.get().enable_forwarding().unwrap();
            let nft = Nft::new(RootSafeBin::open(Path::new("/usr/sbin/nft")).unwrap());
            let mut token = Unprivileged::take().unwrap();
            let root = token.elevate().unwrap();
            let firewall: Firewall = serde_json::from_value(json!({
                "inbound": [{"protocol": "tcp", "ports": [OPEN, OPEN]}],
                "outbound_blocked": [{"protocol": "tcp", "ports": [BLOCKED, BLOCKED]}],
            }))
            .unwrap();
            for table in [
                VmNet::table(
                    GUEST_V6.parse().unwrap(),
                    Uid::from_raw(FIRECRACKER),
                    "198.51.100.1".parse().unwrap(),
                ),
                VmNet::firewall_table(&firewall),
            ] {
                vm.get()
                    .scoped(|| nft.replace_table(&root, &table))
                    .unwrap()
                    .unwrap();
            }

            let listen = |ns: &ScratchNs, port| {
                ns.get()
                    .scoped(|| TcpListener::bind((Ipv6Addr::UNSPECIFIED, port)))
                    .unwrap()
                    .unwrap()
            };
            let listeners = vec![
                listen(&guest, OPEN),
                listen(&guest, CLOSED),
                listen(&host, OPEN),
                listen(&host, BLOCKED),
                listen(&host, DNS),
                listen(&vm, NAMESPACE),
            ];
            Self {
                guest,
                vm,
                host,
                _listeners: listeners,
            }
        }

        fn connects(&self, probe: Probe, to: SocketAddr) -> bool {
            let socket = || Socket::new(Domain::for_address(to), Type::STREAM, None).unwrap();
            match probe {
                Probe::Guest(src) => self.guest.get().scoped(|| {
                    let socket = socket();
                    socket
                        .bind(&SocketAddr::new(src.parse().unwrap(), 0).into())
                        .unwrap();
                    socket.connect_timeout(&to.into(), DROPPED_AFTER).is_ok()
                }),
                Probe::Namespace(uid) => self.vm.get().scoped(|| {
                    setfsuid(Uid::from_raw(uid));
                    socket().connect_timeout(&to.into(), DROPPED_AFTER).is_ok()
                }),
                Probe::Host => self
                    .host
                    .get()
                    .scoped(|| socket().connect_timeout(&to.into(), DROPPED_AFTER).is_ok()),
            }
            .unwrap()
        }

        fn up(rtnl: &Rtnl, link: &str, addrs: &[&str]) -> IfIndex {
            let link = rtnl.link(&Self::name(link)).unwrap().unwrap();
            link.disable_addr_gen().unwrap();
            for addr in addrs {
                link.add_addr(addr.parse().unwrap(), DuplicateAddrDetection::Disabled)
                    .unwrap();
            }
            link.set_up().unwrap();
            link.index()
        }

        fn route(dst: &str, via: Option<&str>, dev: IfIndex) -> Route {
            match dst.parse::<IpNet>().unwrap() {
                IpNet::V4(dst) => Route::V4 {
                    dst,
                    via: via.map(|via| via.parse().unwrap()),
                    dev,
                },
                IpNet::V6(dst) => Route::V6 {
                    dst,
                    via: via.map(|via| via.parse().unwrap()),
                    dev,
                },
            }
        }

        fn name(s: &str) -> IfName {
            s.parse().unwrap()
        }
    }

    #[rstest]
    #[case::guest_ipv4(Probe::Guest("172.16.0.2"), "198.51.100.1:7071", true)]
    #[case::spoofed_ipv4(Probe::Guest("192.0.2.9"), "198.51.100.1:7071", false)]
    #[case::guest_ipv6(Probe::Guest(GUEST_V6), "[2001:db8:ffff::1]:7071", true)]
    #[case::spoofed_ipv6(Probe::Guest("2001:db8::1:0:0:6"), "[2001:db8:ffff::1]:7071", false)]
    #[case::guest_to_a_private_range(Probe::Guest("172.16.0.2"), "10.200.0.1:7071", false)]
    #[case::namespace_as_root(Probe::Namespace(0), "198.51.100.1:7071", true)]
    #[case::namespace_as_firecracker(Probe::Namespace(FIRECRACKER), "198.51.100.1:7071", false)]
    #[case::inbound_to_an_open_port(Probe::Host, "[2001:db8::1:0:0:5]:7071", true)]
    #[case::inbound_to_a_closed_port(Probe::Host, "[2001:db8::1:0:0:5]:7072", false)]
    #[case::outbound_to_a_blocked_port(Probe::Guest("172.16.0.2"), "198.51.100.1:7073", false)]
    #[case::dns_to_the_gateway_reaches_the_resolver(
        Probe::Guest("172.16.0.2"),
        "172.16.0.1:53",
        true
    )]
    #[case::other_ports_on_the_gateway_are_not_forwarded(
        Probe::Guest("172.16.0.2"),
        "172.16.0.1:7071",
        false
    )]
    #[case::guest_to_a_namespace_service(Probe::Guest("172.16.0.2"), "172.16.0.1:7074", false)]
    #[case::host_to_a_namespace_service(Probe::Host, "10.200.0.2:7074", false)]
    fn the_vm_namespace_admits_only_what_its_policy_allows_as_root(
        #[case] probe: Probe,
        #[case] to: &str,
        #[case] reachable: bool,
    ) {
        if !nix::unistd::geteuid().is_root() {
            eprintln!("SKIP VM namespace firewall: needs root");
            return;
        }
        let test = format!("vmfw-{probe:?}-{to}")
            .to_lowercase()
            .replace(|c: char| !c.is_ascii_alphanumeric(), "-");
        let lab = Lab::new(&test);

        assert_eq!(lab.connects(probe, to.parse().unwrap()), reachable);
    }
}
