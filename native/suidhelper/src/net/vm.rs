// SPDX-License-Identifier: MIT
//! One VM's network namespace: built by `vm_launch`, removed by `vm_teardown`.

use super::firewall::Firewall;
use super::{Blocked, Filter, Masquerade, NetId, DSTNAT_PRIORITY, FIREWALL_TABLE, TABLE};
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
use hyperrs_linux::net::{
    IfIndex, IfName, IpNet, Ipv4Net, Ipv6Net, Prefix, RequestError, Rtnl, RtnlOpenError,
};
use hyperrs_process::privilege::Root;
use nix::errno::Errno;
use nix::unistd::{Gid, Uid};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
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
    #[error("listing proxy neighbours: {0}")]
    ProxyNeighs(#[source] RequestError),
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

        let host_uplink = Self::existing(&host, net.uplink())?;
        host_uplink.add_proxy_neigh(guest)?;
        let host_addrs: Vec<IpAddr> = host_uplink.addrs()?.into_iter().map(IpNet::addr).collect();

        ns.enable_forwarding()?;
        ns.scoped(|| {
            nft.replace_table(
                root,
                &Self::table(
                    guest,
                    uid,
                    net.resolver().addr(),
                    net.blocked(),
                    &host_addrs,
                ),
            )
        })??;
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
        if let Some(net) = net {
            Self::sweep_proxy_neighs(net)?;
        }
        Ok(())
    }

    fn sweep_proxy_neighs(net: &Net) -> Result<(), VmNetError> {
        let host = Rtnl::open()?;
        let Some(uplink) = host.link(net.uplink())? else {
            return Ok(());
        };
        for addr in uplink.proxy_neighs().map_err(VmNetError::ProxyNeighs)? {
            let Some(net_id) = net.ipv6_prefix().guest_net_id(addr) else {
                continue;
            };
            if host.link(&net_id.host_veth())?.is_none() {
                uplink.delete_proxy_neigh(addr)?;
            }
        }
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
    fn table(
        guest: Ipv6Addr,
        uid: Uid,
        resolver: Ipv4Addr,
        blocked: &Blocked,
        host: &[IpAddr],
    ) -> Table {
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
                    rules: std::iter::once(Rule {
                        matches: vec![Match::CtState(CtState::Invalid)],
                        action: Action::Drop,
                    })
                    .chain(blocked.ranges().map(|range| Rule {
                        matches: vec![
                            Match::Iifname(Iface::Named(TAP.clone())),
                            Self::daddr(range),
                        ],
                        action: Action::Drop,
                    }))
                    .chain(
                        host.iter()
                            .map(|addr| Self::host_route(*addr))
                            .chain([IpNet::V4(NetId::transit_range())])
                            .map(|daddr| Rule {
                                matches: vec![
                                    Match::Iifname(Iface::Named(TAP.clone())),
                                    Self::daddr(daddr),
                                    Match::CtState(CtState::New),
                                ],
                                action: Action::Drop,
                            }),
                    )
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

    fn daddr(net: IpNet) -> Match {
        match net {
            IpNet::V4(net) => Match::Ipv4Daddr(net),
            IpNet::V6(net) => Match::Ipv6Daddr(net),
        }
    }

    fn host_route(addr: IpAddr) -> IpNet {
        match addr {
            IpAddr::V4(addr) => IpNet::V4(Ipv4Net {
                addr,
                prefix: Self::prefix(32),
            }),
            IpAddr::V6(addr) => IpNet::V6(Ipv6Net {
                addr,
                prefix: Self::prefix(128),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Blocked, Firewall, VmNet, TAP, UPLINK};
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
    use socket2::{Domain, Protocol, Socket, Type};
    use std::io::Read;
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, TcpListener};
    use std::path::Path;
    use std::time::Duration;

    const OPEN: u16 = 7071;
    const CLOSED: u16 = 7072;
    const BLOCKED: u16 = 7073;
    const DNS: u16 = 53;
    const NAMESPACE: u16 = 7074;
    const DROPPED_AFTER: Duration = Duration::from_secs(3);
    const HOST_ADDRS: [&str; 2] = ["198.51.100.2", "2001:db8:ffff::2"];
    const INVALID_PORT: u16 = 7075;
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
            Self::with_blocked(test, &Blocked::default())
        }

        fn with_blocked(test: &str, blocked: &Blocked) -> Self {
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
                    "198.51.100.2/32",
                    "fe80::1/64",
                    "2001:db8:ffff::1/128",
                    "2001:db8:ffff::2/128",
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
                (&h, Self::route("172.16.0.0/30", Some("10.200.0.2"), wan)),
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
                    blocked,
                    &HOST_ADDRS.map(|addr| addr.parse().unwrap()),
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

        fn invalid_segment_arrives_from(&self, to: SocketAddrV4) -> Vec<Ipv4Addr> {
            let capture = self
                .host
                .get()
                .scoped(|| Socket::new(Domain::IPV4, Type::RAW, Some(Protocol::TCP)))
                .unwrap()
                .unwrap();
            capture.set_read_timeout(Some(DROPPED_AFTER)).unwrap();
            let src: Ipv4Addr = "172.16.0.2".parse().unwrap();
            let mut segment = [0u8; 20];
            segment[0..2].copy_from_slice(&40_000u16.to_be_bytes());
            segment[2..4].copy_from_slice(&to.port().to_be_bytes());
            segment[4..8].copy_from_slice(&1u32.to_be_bytes());
            segment[12] = 5 << 4;
            segment[13] = 0x03;
            segment[14..16].copy_from_slice(&64_240u16.to_be_bytes());
            let pseudo: Vec<u8> = [&src.octets()[..], &to.ip().octets()[..], &[0, 6, 0, 20]]
                .concat()
                .into_iter()
                .chain(segment)
                .collect();
            let sum = pseudo
                .chunks(2)
                .map(|w| u32::from(u16::from_be_bytes([w[0], w[1]])))
                .sum::<u32>();
            let folded = !(((sum & 0xffff) + (sum >> 16)) as u16);
            segment[16..18].copy_from_slice(&folded.to_be_bytes());
            self.guest
                .get()
                .scoped(|| {
                    let send = Socket::new(Domain::IPV4, Type::RAW, Some(Protocol::TCP)).unwrap();
                    send.bind(&SocketAddr::new(src.into(), 0).into()).unwrap();
                    send.send_to(&segment, &SocketAddr::new((*to.ip()).into(), 0).into())
                        .unwrap();
                })
                .unwrap();

            let mut seen = Vec::new();
            let mut packet = [0u8; 1500];
            while let Ok(n) = (&capture).read(&mut packet) {
                let ihl = usize::from(packet[0] & 0x0f) * 4;
                if n < ihl + 4 {
                    continue;
                }
                let port = u16::from_be_bytes([packet[ihl + 2], packet[ihl + 3]]);
                if port == to.port() {
                    seen.push(Ipv4Addr::new(
                        packet[12], packet[13], packet[14], packet[15],
                    ));
                }
            }
            seen
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
    #[case::guest_to_the_host_itself(Probe::Guest("172.16.0.2"), "198.51.100.2:7071", false)]
    #[case::guest_to_the_host_itself_over_ipv6(
        Probe::Guest(GUEST_V6),
        "[2001:db8:ffff::2]:7071",
        false
    )]
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

    #[rstest]
    fn an_invalid_segment_from_the_guest_never_leaves_the_namespace_as_root() {
        if !nix::unistd::geteuid().is_root() {
            eprintln!("SKIP invalid segment: needs root");
            return;
        }
        let lab = Lab::new("vmfw-invalid");

        assert_eq!(
            lab.invalid_segment_arrives_from(SocketAddrV4::new(
                "198.51.100.1".parse().unwrap(),
                INVALID_PORT
            )),
            Vec::<Ipv4Addr>::new()
        );
    }

    #[rstest]
    fn teardown_drops_proxy_entries_whose_veth_is_gone_and_keeps_the_rest_as_root() {
        if !nix::unistd::geteuid().is_root() {
            eprintln!("SKIP proxy sweep: needs root");
            return;
        }
        let host = ScratchNs::new("sweep-host");
        let peer = ScratchNs::new("sweep-peer");
        let net: crate::config::Net =
            serde_json::from_value(json!({"uplink": "up0", "ipv6_prefix": "2001:db8::/64"}))
                .unwrap();
        let (live, dead): (Ipv6Addr, Ipv6Addr) = (
            "2001:db8::1:0:0:4".parse().unwrap(),
            "2001:db8::1:0:0:3".parse().unwrap(),
        );
        let rtnl = host.get().rtnl().unwrap();
        rtnl.create_veth(&Lab::name("up0"), &Lab::name("wan0"), peer.get())
            .unwrap();
        rtnl.create_veth(&Lab::name("vm-veth-4"), &Lab::name("uplink"), peer.get())
            .unwrap();
        let uplink = rtnl.link(&Lab::name("up0")).unwrap().unwrap();
        for addr in [live, dead] {
            uplink.add_proxy_neigh(addr).unwrap();
        }

        host.get()
            .scoped(|| {
                VmNet {
                    id: &"vsweepgone".parse().unwrap(),
                }
                .teardown(Some(&net))
            })
            .unwrap()
            .unwrap();

        assert_eq!(uplink.proxy_neighs().unwrap(), vec![live]);
    }

    mod hostile_guest {
        //! A guest that forges, impersonates and probes, against the namespace's tables.
        //!
        //! Laws:
        //! - a TCP segment whose source port's high byte reads as a neighbour-discovery
        //!   type is not neighbour discovery: it never reaches a namespace service;
        //! - the namespace's link-local and uplink addresses serve the guest nothing;
        //! - the DNS redirect never carries a forged source to the resolver;
        //! - the jailed Firecracker reaches not even its own guest;
        //! - with `[net] blocked` empty, the host's addresses and the transit range stay
        //!   unreachable from the guest;
        //! - a router advertisement from the guest never reaches the namespace, even on a
        //!   `tap0` that would otherwise act on it.

        use super::{Lab, Probe, DROPPED_AFTER, FIRECRACKER, NAMESPACE};
        use crate::net::Blocked;
        use pretty_assertions::assert_eq;
        use rstest::rstest;
        use socket2::{Domain, Protocol, Socket, Type};
        use std::net::{IpAddr, Ipv6Addr, SocketAddr, SocketAddrV6};
        use std::process::Command;
        use std::time::Duration;

        const SOLICIT_SPORT: u16 = 135 << 8;
        const ADVERT_SPORT: u16 = 136 << 8;
        const ROUTER_ADVERT: u8 = 134;
        const RA_PREFIX: &str = "2001:db8:bad::";

        fn skip_unless_root(test: &str) -> bool {
            if nix::unistd::geteuid().is_root() {
                return false;
            }
            eprintln!("SKIP {test}: needs root");
            true
        }

        fn lab_name(parts: &str) -> String {
            let mut name: String = parts
                .to_lowercase()
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect();
            name.truncate(40);
            name
        }

        fn eth0(lab: &Lab) -> u32 {
            lab.guest
                .get()
                .rtnl()
                .unwrap()
                .link(&Lab::name("eth0"))
                .unwrap()
                .unwrap()
                .index()
                .get()
        }

        /// Link-local destinations are scoped to the guest's `eth0`.
        fn target(lab: &Lab, to: &str) -> SocketAddr {
            let to: SocketAddr = to.parse().unwrap();
            match to {
                SocketAddr::V6(v6) if v6.ip().is_unicast_link_local() => {
                    SocketAddrV6::new(*v6.ip(), v6.port(), 0, eth0(lab)).into()
                }
                to => to,
            }
        }

        fn guest_connects(lab: &Lab, src: Option<&str>, sport: u16, to: &str) -> bool {
            let to = target(lab, to);
            lab.guest
                .get()
                .scoped(|| {
                    let socket = Socket::new(Domain::for_address(to), Type::STREAM, None).unwrap();
                    socket.set_reuse_address(true).unwrap();
                    let src: IpAddr = match (src, to) {
                        (Some(src), _) => src.parse().unwrap(),
                        (None, SocketAddr::V4(_)) => IpAddr::from([0, 0, 0, 0]),
                        (None, SocketAddr::V6(_)) => Ipv6Addr::UNSPECIFIED.into(),
                    };
                    socket.bind(&SocketAddr::new(src, sport).into()).unwrap();
                    socket.connect_timeout(&to.into(), DROPPED_AFTER).is_ok()
                })
                .unwrap()
        }

        #[rstest]
        #[case::solicit_lookalike_to_a_namespace_service(
            None,
            SOLICIT_SPORT,
            "172.16.0.1:7074",
            false
        )]
        #[case::advert_lookalike_to_a_namespace_service(
            None,
            ADVERT_SPORT,
            "172.16.0.1:7074",
            false
        )]
        #[case::solicit_lookalike_over_link_local(None, SOLICIT_SPORT, "[fe80::1]:7074", false)]
        #[case::advert_lookalike_over_link_local(None, ADVERT_SPORT, "[fe80::1]:7074", false)]
        #[case::link_local_to_a_namespace_service(None, 0, "[fe80::1]:7074", false)]
        #[case::uplink_address_to_a_namespace_service(None, 0, "10.200.0.2:7074", false)]
        #[case::forged_source_through_the_dns_redirect(
            Some("192.0.2.9"),
            0,
            "172.16.0.1:53",
            false
        )]
        #[case::forged_ipv6_source_to_the_host(
            Some("2001:db8::1:0:0:6"),
            SOLICIT_SPORT,
            "[2001:db8:ffff::1]:7071",
            false
        )]
        #[case::lookalike_port_still_reaches_the_internet(
            None,
            SOLICIT_SPORT,
            "198.51.100.1:7071",
            true
        )]
        fn a_hostile_guest_reaches_only_what_policy_allows_as_root(
            #[case] src: Option<&str>,
            #[case] sport: u16,
            #[case] to: &str,
            #[case] reachable: bool,
        ) {
            if skip_unless_root("hostile guest") {
                return;
            }
            let lab = Lab::new(&lab_name(&format!("hg-{src:?}-{sport}-{to}")));

            assert_eq!(guest_connects(&lab, src, sport, to), reachable);
        }

        #[rstest]
        #[case::as_firecracker(FIRECRACKER, false)]
        #[case::as_root(0, true)]
        fn the_jailed_firecracker_cannot_reach_its_own_guest_as_root(
            #[case] uid: u32,
            #[case] reachable: bool,
        ) {
            if skip_unless_root("namespace to guest") {
                return;
            }
            let lab = Lab::new(&format!("hg-fc-{uid}"));

            assert_eq!(
                lab.connects(Probe::Namespace(uid), "172.16.0.2:7071".parse().unwrap()),
                reachable
            );
        }

        #[rstest]
        #[case::the_host_veth("10.200.0.1:7071", false)]
        #[case::a_host_address("198.51.100.2:7071", false)]
        #[case::a_host_address_over_ipv6("[2001:db8:ffff::2]:7071", false)]
        #[case::the_internet("198.51.100.1:7071", true)]
        fn with_nothing_blocked_the_guest_still_never_reaches_the_host_as_root(
            #[case] to: &str,
            #[case] reachable: bool,
        ) {
            if skip_unless_root("empty blocked") {
                return;
            }
            let lab = Lab::with_blocked(
                &lab_name(&format!("hg-nb-{to}")),
                &Blocked::try_from(Vec::new()).unwrap(),
            );

            assert_eq!(guest_connects(&lab, None, 0, to), reachable);
        }

        /// An RA from `fe80::2` on `eth0` announcing `RA_PREFIX/64` and itself as a default
        /// router.
        fn send_router_advert(lab: &Lab) {
            let index = eth0(lab);
            lab.guest
                .get()
                .scoped(|| {
                    let socket =
                        Socket::new(Domain::IPV6, Type::RAW, Some(Protocol::ICMPV6)).unwrap();
                    socket.set_multicast_hops_v6(255).unwrap();
                    socket.set_unicast_hops_v6(255).unwrap();
                    socket.set_multicast_if_v6(index).unwrap();
                    let src = SocketAddrV6::new("fe80::2".parse().unwrap(), 0, 0, index);
                    socket.bind(&src.into()).unwrap();
                    let mut ra = vec![ROUTER_ADVERT, 0, 0, 0, 64, 0];
                    ra.extend_from_slice(&1800u16.to_be_bytes());
                    ra.extend_from_slice(&[0; 8]);
                    ra.extend_from_slice(&[3, 4, 64, 0xc0]);
                    ra.extend_from_slice(&86_400u32.to_be_bytes());
                    ra.extend_from_slice(&14_400u32.to_be_bytes());
                    ra.extend_from_slice(&[0; 4]);
                    ra.extend_from_slice(&RA_PREFIX.parse::<Ipv6Addr>().unwrap().octets());
                    let all_nodes = SocketAddrV6::new("ff02::1".parse().unwrap(), 0, 0, index);
                    socket.send_to(&ra, &all_nodes.into()).unwrap();
                })
                .unwrap();
        }

        fn namespace_routes(lab: &Lab) -> String {
            let out = lab
                .vm
                .get()
                .scoped(|| Command::new("ip").args(["-6", "route", "show"]).output())
                .unwrap()
                .unwrap();
            String::from_utf8(out.stdout).unwrap()
        }

        #[rstest]
        fn a_router_advert_from_the_guest_never_reaches_the_namespace_as_root() {
            if skip_unless_root("guest router advert") {
                return;
            }
            let lab = Lab::new("hg-ra");
            lab.vm
                .get()
                .scoped(|| {
                    std::fs::write("/proc/sys/net/ipv6/conf/tap0/accept_ra", "2").unwrap();
                })
                .unwrap();

            send_router_advert(&lab);
            std::thread::sleep(Duration::from_secs(1));

            let routes = namespace_routes(&lab);
            assert!(
                !routes.contains("proto ra") && !routes.contains(RA_PREFIX.trim_end_matches(':')),
                "{routes}"
            );
        }

        #[rstest]
        fn a_namespace_service_is_reachable_from_the_namespace_itself_as_root() {
            if skip_unless_root("namespace service control") {
                return;
            }
            let lab = Lab::new("hg-ctl");

            assert!(lab.connects(
                Probe::Namespace(0),
                format!("127.0.0.1:{NAMESPACE}").parse().unwrap()
            ));
        }
    }
}
