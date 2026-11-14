//! The host firewall `host_init` installs, observed with real TCP connections.
//!
//! Three scratch namespaces stand in for the host, one VM's namespace (joined to the
//! host through `vm-veth-0`) and the internet beyond the uplink (`if0`). Laws:
//! - a VM reaches public addresses, and nothing on the host or in non-public ranges;
//! - the host does not stop anything reaching a VM: that is the VM namespace's firewall.
//!
//! The reachable rows prove the topology routes, so the unreachable ones are the
//! firewall and not a missing route.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use hyperrs_linux::net::link::DuplicateAddrDetection;
use hyperrs_linux::net::netns::NetNs;
use hyperrs_linux::net::route::Route;
use hyperrs_linux::net::{IfIndex, IfName, IpNet, Rtnl};
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::json;
use socket2::{Domain, Protocol, Socket, Type};
use std::fs;
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

mod support;
use support::{is_root, ScratchNs};

const PORT: u16 = 7070;
const DROPPED_AFTER: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy)]
enum Side {
    Host,
    Vm,
    Wan,
}

struct Lab {
    host: ScratchNs,
    vm: ScratchNs,
    wan: ScratchNs,
    _listeners: Vec<TcpListener>,
}

impl Lab {
    fn new(test: &str) -> Self {
        let lab = Self {
            host: ScratchNs::new(&format!("{test}-host")),
            vm: ScratchNs::new(&format!("{test}-vm")),
            wan: ScratchNs::new(&format!("{test}-wan")),
            _listeners: Vec::new(),
        };
        let host = lab.host.get().rtnl().unwrap();
        let vm = lab.vm.get().rtnl().unwrap();
        let wan = lab.wan.get().rtnl().unwrap();

        host.create_veth(
            &Self::name("vm-veth-0"),
            &Self::name("uplink"),
            lab.vm.get(),
        )
        .unwrap();
        host.create_veth(&Self::name("if0"), &Self::name("wan"), lab.wan.get())
            .unwrap();
        Self::up(&host, "lo", &[]);
        let veth = Self::up(&host, "vm-veth-0", &["10.200.0.1/30", "fe80::1/64"]);
        let if0 = Self::up(
            &host,
            "if0",
            &[
                "203.0.113.2/24",
                "10.9.0.2/24",
                "169.254.0.2/16",
                "fe80::a/64",
            ],
        );
        Self::up(&vm, "lo", &["2001:db8:1::9/128"]);
        let uplink = Self::up(
            &vm,
            "uplink",
            &["10.200.0.2/30", "fe80::2/64", "2001:db8::1:0:0:5/128"],
        );
        Self::up(&wan, "lo", &["2001:db8::99/128"]);
        let wan_link = Self::up(
            &wan,
            "wan",
            &[
                "203.0.113.1/24",
                "10.9.0.1/24",
                "169.254.169.254/16",
                "fe80::b/64",
                "2001:db8:ffff::1/128",
            ],
        );
        for (rtnl, route) in [
            (&vm, Self::route("0.0.0.0/0", "10.200.0.1", uplink)),
            (&vm, Self::route("::/0", "fe80::1", uplink)),
            (&host, Self::route("2001:db8::1:0:0:5/128", "fe80::2", veth)),
            (&host, Self::route("2001:db8:1::/64", "fe80::2", veth)),
            (&host, Self::route("::/0", "fe80::b", if0)),
            (&wan, Self::route("10.200.0.0/16", "203.0.113.2", wan_link)),
            (
                &wan,
                Self::route("2001:db8:0:0:1::/80", "fe80::a", wan_link),
            ),
            (&wan, Self::route("2001:db8:1::/64", "fe80::a", wan_link)),
        ] {
            rtnl.add_route(&route).unwrap();
        }

        let tmp = TempDir::new().unwrap();
        let cfg = tmp.path().join("config.toml");
        fs::write(
            &cfg,
            "work_dir = \"/srv/hyper\"\n[net]\nuplink = \"if0\"\nipv6_prefix = \"2001:db8::/64\"\n",
        )
        .unwrap();
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o644)).unwrap();
        lab.host.run(&cfg, json!({"op": "host_init"})).success();

        let listen = |ns: &ScratchNs| {
            ns.get()
                .scoped(|| TcpListener::bind((Ipv6Addr::UNSPECIFIED, PORT)))
                .unwrap()
                .unwrap()
        };
        Self {
            _listeners: vec![listen(&lab.host), listen(&lab.vm), listen(&lab.wan)],
            ..lab
        }
    }

    fn ns(&self, from: Side) -> &NetNs {
        match from {
            Side::Host => self.host.get(),
            Side::Vm => self.vm.get(),
            Side::Wan => self.wan.get(),
        }
    }

    fn connects(&self, from: Side, to: IpAddr) -> bool {
        self.ns(from)
            .scoped(|| {
                TcpStream::connect_timeout(&SocketAddr::from((to, PORT)), DROPPED_AFTER).is_ok()
            })
            .unwrap()
    }

    fn invalid_segment_arrives_from(&self, to: SocketAddrV4) -> Vec<Ipv4Addr> {
        let capture = self
            .wan
            .get()
            .scoped(|| Socket::new(Domain::IPV4, Type::RAW, Some(Protocol::TCP)))
            .unwrap()
            .unwrap();
        capture.set_read_timeout(Some(DROPPED_AFTER)).unwrap();
        let src: Ipv4Addr = "10.200.0.2".parse().unwrap();
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
        self.vm
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
        for addr in addrs {
            link.add_addr(addr.parse().unwrap(), DuplicateAddrDetection::Disabled)
                .unwrap();
        }
        link.set_up().unwrap();
        link.index()
    }

    fn name(s: &str) -> IfName {
        s.parse().unwrap()
    }

    fn route(dst: &str, via: &str, dev: IfIndex) -> Route {
        match dst.parse::<IpNet>().unwrap() {
            IpNet::V4(dst) => Route::V4 {
                dst,
                via: Some(via.parse().unwrap()),
                dev,
            },
            IpNet::V6(dst) => Route::V6 {
                dst,
                via: Some(via.parse().unwrap()),
                dev,
            },
        }
    }
}

#[rstest]
#[case::vm_to_the_internet(Side::Vm, "203.0.113.1", true)]
#[case::vm_to_its_host_veth(Side::Vm, "10.200.0.1", false)]
#[case::vm_to_the_host_uplink(Side::Vm, "203.0.113.2", false)]
#[case::vm_to_a_private_network(Side::Vm, "10.9.0.1", false)]
#[case::vm_to_cloud_metadata(Side::Vm, "169.254.169.254", false)]
#[case::host_to_the_vm(Side::Host, "10.200.0.2", true)]
#[case::internet_routing_into_the_transit_range(Side::Wan, "10.200.0.2", false)]
#[case::vm_to_the_internet_over_ipv6(Side::Vm, "2001:db8:ffff::1", true)]
#[case::vm_to_the_node_prefix_outside_the_vm_range(Side::Vm, "2001:db8::99", false)]
#[case::internet_to_a_guest(Side::Wan, "2001:db8::1:0:0:5", true)]
#[case::internet_into_a_vm_namespace_outside_the_vm_range(Side::Wan, "2001:db8:1::9", false)]
fn the_host_firewall_confines_vms_as_root(
    #[case] from: Side,
    #[case] to: &str,
    #[case] reachable: bool,
) {
    if !is_root() {
        eprintln!("SKIP host firewall: needs root");
        return;
    }
    let lab = Lab::new(
        &format!("fw-{from:?}-{to}")
            .to_lowercase()
            .replace(['.', ':'], "-"),
    );

    assert_eq!(lab.connects(from, to.parse().unwrap()), reachable);
}

#[rstest]
fn host_init_keeps_honouring_router_advertisements_on_the_uplink_as_root() {
    if !is_root() {
        eprintln!("SKIP host firewall: needs root");
        return;
    }
    let lab = Lab::new("fw-accept-ra");

    let accept_ra = lab
        .host
        .get()
        .scoped(|| fs::read_to_string("/proc/sys/net/ipv6/conf/if0/accept_ra").unwrap())
        .unwrap();

    assert_eq!(accept_ra.trim(), "2");
}

#[rstest]
fn an_invalid_segment_from_a_vm_never_leaves_the_host_as_root() {
    if !is_root() {
        eprintln!("SKIP invalid segment: needs root");
        return;
    }
    let lab = Lab::new("fw-invalid");

    assert_eq!(
        lab.invalid_segment_arrives_from(SocketAddrV4::new("203.0.113.1".parse().unwrap(), 7075)),
        Vec::<Ipv4Addr>::new()
    );
}
