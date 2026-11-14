//! The host firewall `host_init` installs, attacked from a compromised VM namespace.
//!
//! Four scratch namespaces stand in for the host, two VMs' namespaces (`vm-veth-0`,
//! `vm-veth-1`) and the internet beyond `if0`. Every address a probe uses is routed both
//! ways, so a refused probe is the firewall and not a missing route. Laws:
//! - a VM namespace opens nothing on the host: not through its veth's IPv4 or link-local
//!   address, not through host addresses off the uplink, not over UDP;
//! - a VM namespace reaches no other VM's transit addresses, only its public IPv6;
//! - a packet from a VM leaves the host only from that VM's transit or VM-range source;
//! - a TCP or UDP packet whose first transport byte reads as a neighbour-discovery type is
//!   not neighbour discovery: the host's ND allowance never admits it;
//! - isolation from the host and the transit range holds even with `[net] blocked = []`;
//! - nothing the internet sends, conntrack-invalid or not, is forwarded into the transit
//!   range;
//! - `vm_firewall` acts only on a real namespace pinned at the VM's own name: a plain file
//!   or a symlink there is refused, and no other namespace gains a table.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use hyperrs_linux::net::link::DuplicateAddrDetection;
use hyperrs_linux::net::netns::NetNs;
use hyperrs_linux::net::route::Route;
use hyperrs_linux::net::{IfIndex, IfName, IpNet, Rtnl};
use predicates::str::contains;
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::json;
use socket2::{Domain, Protocol, Socket, Type};
use std::fs;
use std::io::Read;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6, TcpListener, UdpSocket};
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

mod support;
use support::{is_root, ScratchNs};

const PORT: u16 = 7080;
const DROPPED_AFTER: Duration = Duration::from_secs(3);
const NEIGHBOR_SOLICIT_SPORT: u16 = 135 << 8;
const NEIGHBOR_ADVERT_SPORT: u16 = 136 << 8;

#[derive(Debug, Clone, Copy)]
enum Side {
    Vm0,
    Wan,
}

struct Lab {
    _host: ScratchNs,
    vm0: ScratchNs,
    _vm1: ScratchNs,
    wan: ScratchNs,
    vm0_uplink: IfIndex,
    _tcp: Vec<TcpListener>,
    udp: Vec<(&'static str, UdpSocket)>,
}

impl Lab {
    fn new(test: &str, net_extra: &str) -> Self {
        let host = ScratchNs::new(&format!("{test}-h"));
        let vm0 = ScratchNs::new(&format!("{test}-0"));
        let vm1 = ScratchNs::new(&format!("{test}-1"));
        let wan = ScratchNs::new(&format!("{test}-w"));
        let h = host.get().rtnl().unwrap();
        let v0 = vm0.get().rtnl().unwrap();
        let v1 = vm1.get().rtnl().unwrap();
        let w = wan.get().rtnl().unwrap();

        h.create_veth(&name("vm-veth-0"), &name("uplink"), vm0.get())
            .unwrap();
        h.create_veth(&name("vm-veth-1"), &name("uplink"), vm1.get())
            .unwrap();
        h.create_veth(&name("if0"), &name("wan"), wan.get())
            .unwrap();
        up(&h, "lo", &["198.51.100.7/32"]);
        let veth0 = up(&h, "vm-veth-0", &["10.200.0.1/30", "fe80::1/64"]);
        let veth1 = up(&h, "vm-veth-1", &["10.200.0.5/30", "fe80::1/64"]);
        let if0 = up(
            &h,
            "if0",
            &[
                "203.0.113.2/24",
                "10.9.0.2/24",
                "169.254.0.2/16",
                "fe80::a/64",
                "2001:db8::2/64",
            ],
        );
        up(&v0, "lo", &["192.0.2.50/32", "2001:db8:1::9/128"]);
        let vm0_uplink = up(
            &v0,
            "uplink",
            &["10.200.0.2/30", "fe80::2/64", "2001:db8::1:0:0:0/128"],
        );
        up(&v1, "lo", &[]);
        let vm1_uplink = up(
            &v1,
            "uplink",
            &["10.200.0.6/30", "fe80::2/64", "2001:db8::1:0:0:1/128"],
        );
        up(&w, "lo", &[]);
        let wan_link = up(
            &w,
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
            (&v0, route("0.0.0.0/0", "10.200.0.1", vm0_uplink)),
            (&v0, route("::/0", "fe80::1", vm0_uplink)),
            (&v1, route("0.0.0.0/0", "10.200.0.5", vm1_uplink)),
            (&v1, route("::/0", "fe80::1", vm1_uplink)),
            (&h, route("2001:db8::1:0:0:0/128", "fe80::2", veth0)),
            (&h, route("2001:db8::1:0:0:1/128", "fe80::2", veth1)),
            (&h, route("2001:db8:1::/64", "fe80::2", veth0)),
            (&h, route("192.0.2.50/32", "10.200.0.2", veth0)),
            (&h, route("::/0", "fe80::b", if0)),
            (&w, route("10.200.0.0/16", "203.0.113.2", wan_link)),
            (&w, route("192.0.2.50/32", "203.0.113.2", wan_link)),
            (&w, route("2001:db8:0:0:1::/80", "fe80::a", wan_link)),
            (&w, route("2001:db8:1::/64", "fe80::a", wan_link)),
        ] {
            rtnl.add_route(&route).unwrap();
        }

        let tmp = TempDir::new().unwrap();
        let cfg = tmp.path().join("config.toml");
        fs::write(
            &cfg,
            format!(
                "work_dir = \"/srv/hyper\"\n[net]\nuplink = \"if0\"\n\
                 ipv6_prefix = \"2001:db8::/64\"\n{net_extra}"
            ),
        )
        .unwrap();
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o644)).unwrap();
        host.get().enable_forwarding().unwrap();
        host.run(&cfg, json!({"op": "host_init"})).success();

        let tcp = [&host, &vm0, &vm1, &wan]
            .into_iter()
            .map(|ns| {
                ns.get()
                    .scoped(|| TcpListener::bind((Ipv6Addr::UNSPECIFIED, PORT)))
                    .unwrap()
                    .unwrap()
            })
            .collect();
        let udp = [("host", &host), ("wan", &wan)]
            .into_iter()
            .map(|(side, ns)| {
                let socket = ns
                    .get()
                    .scoped(|| UdpSocket::bind((Ipv6Addr::UNSPECIFIED, PORT)))
                    .unwrap()
                    .unwrap();
                socket.set_read_timeout(Some(DROPPED_AFTER)).unwrap();
                (side, socket)
            })
            .collect();
        Self {
            _host: host,
            vm0,
            _vm1: vm1,
            wan,
            vm0_uplink,
            _tcp: tcp,
            udp,
        }
    }

    fn ns(&self, side: Side) -> &NetNs {
        match side {
            Side::Vm0 => self.vm0.get(),
            Side::Wan => self.wan.get(),
        }
    }

    /// Link-local destinations are scoped to vm0's `uplink`, the only link a VM has.
    fn target(&self, to: &str) -> SocketAddr {
        match to.parse().unwrap() {
            IpAddr::V6(addr) if addr.is_unicast_link_local() => {
                SocketAddrV6::new(addr, PORT, 0, self.vm0_uplink.get()).into()
            }
            addr => SocketAddr::new(addr, PORT),
        }
    }

    fn socket(&self, ty: Type, src: Option<&str>, sport: u16, to: SocketAddr) -> Socket {
        let socket = Socket::new(Domain::for_address(to), ty, None).unwrap();
        socket.set_reuse_address(true).unwrap();
        let src = src.map_or_else(
            || match to {
                SocketAddr::V4(_) => IpAddr::from([0, 0, 0, 0]),
                SocketAddr::V6(_) => Ipv6Addr::UNSPECIFIED.into(),
            },
            |src| src.parse().unwrap(),
        );
        socket.bind(&SocketAddr::new(src, sport).into()).unwrap();
        socket
    }

    fn connects(&self, from: Side, src: Option<&str>, sport: u16, to: &str) -> bool {
        let to = self.target(to);
        self.ns(from)
            .scoped(|| {
                self.socket(Type::STREAM, src, sport, to)
                    .connect_timeout(&to.into(), DROPPED_AFTER)
                    .is_ok()
            })
            .unwrap()
    }

    /// Whether a datagram vm0 sends to `to` arrives at the listener on `side`.
    fn datagram_arrives(&self, sport: u16, to: &str, side: &str) -> bool {
        let to = self.target(to);
        self.vm0
            .get()
            .scoped(|| {
                self.socket(Type::DGRAM, None, sport, to)
                    .send_to(b"probe", &to.into())
                    .unwrap();
            })
            .unwrap();
        let (_, listener) = self.udp.iter().find(|(s, _)| *s == side).unwrap();
        let mut buf = [0u8; 16];
        listener.recv(&mut buf).is_ok_and(|n| &buf[..n] == b"probe")
    }

    /// The sources of SYN+FIN segments (conntrack-invalid) to `dst` that the wan sends
    /// and vm0's namespace receives.
    fn invalid_segment_from_wan_reaches_vm0(&self, dst: Ipv4Addr) -> Vec<Ipv4Addr> {
        let capture = self
            .vm0
            .get()
            .scoped(|| Socket::new(Domain::IPV4, Type::RAW, Some(Protocol::TCP)))
            .unwrap()
            .unwrap();
        capture.set_read_timeout(Some(DROPPED_AFTER)).unwrap();
        let src = Ipv4Addr::new(203, 0, 113, 1);
        let segment = syn_fin(src, dst);
        self.wan
            .get()
            .scoped(|| {
                let send = Socket::new(Domain::IPV4, Type::RAW, Some(Protocol::TCP)).unwrap();
                send.send_to(&segment, &SocketAddr::new(dst.into(), 0).into())
                    .unwrap();
            })
            .unwrap();

        let mut seen = Vec::new();
        let mut packet = [0u8; 1500];
        while let Ok(n) = (&capture).read(&mut packet) {
            let ihl = usize::from(packet[0] & 0x0f) * 4;
            if n >= ihl + 4 && u16::from_be_bytes([packet[ihl + 2], packet[ihl + 3]]) == PORT {
                seen.push(Ipv4Addr::new(
                    packet[12], packet[13], packet[14], packet[15],
                ));
            }
        }
        seen
    }
}

/// A checksummed TCP header with SYN and FIN both set, which conntrack calls invalid.
fn syn_fin(src: Ipv4Addr, dst: Ipv4Addr) -> [u8; 20] {
    let mut segment = [0u8; 20];
    segment[0..2].copy_from_slice(&40_000u16.to_be_bytes());
    segment[2..4].copy_from_slice(&PORT.to_be_bytes());
    segment[4..8].copy_from_slice(&1u32.to_be_bytes());
    segment[12] = 5 << 4;
    segment[13] = 0x03;
    segment[14..16].copy_from_slice(&64_240u16.to_be_bytes());
    let sum = [
        &src.octets()[..],
        &dst.octets()[..],
        &[0, 6, 0, 20],
        &segment[..],
    ]
    .concat()
    .chunks(2)
    .map(|w| u32::from(u16::from_be_bytes([w[0], w[1]])))
    .sum::<u32>();
    let folded = !(((sum & 0xffff) + (sum >> 16)) as u16);
    segment[16..18].copy_from_slice(&folded.to_be_bytes());
    segment
}

fn name(s: &str) -> IfName {
    s.parse().unwrap()
}

fn up(rtnl: &Rtnl, link: &str, addrs: &[&str]) -> IfIndex {
    let link = rtnl.link(&name(link)).unwrap().unwrap();
    for addr in addrs {
        link.add_addr(addr.parse().unwrap(), DuplicateAddrDetection::Disabled)
            .unwrap();
    }
    link.set_up().unwrap();
    link.index()
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

fn lab_name(parts: &str) -> String {
    let mut name: String = parts
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    name.truncate(48);
    name
}

#[rstest]
#[case::to_the_internet(Side::Vm0, None, 0, "203.0.113.1", true)]
#[case::to_another_vms_public_ipv6(Side::Vm0, None, 0, "2001:db8::1:0:0:1", true)]
#[case::to_another_vms_host_veth(Side::Vm0, None, 0, "10.200.0.5", false)]
#[case::to_another_vms_uplink(Side::Vm0, None, 0, "10.200.0.6", false)]
#[case::to_a_host_address_off_the_uplink(Side::Vm0, None, 0, "198.51.100.7", false)]
#[case::to_the_hosts_own_node_prefix_address(Side::Vm0, None, 0, "2001:db8::2", false)]
#[case::to_the_host_veth_link_local(Side::Vm0, None, 0, "fe80::1", false)]
#[case::spoofed_ipv4_source(Side::Vm0, Some("192.0.2.50"), 0, "203.0.113.1", false)]
#[case::spoofed_ipv6_source(Side::Vm0, Some("2001:db8:1::9"), 0, "2001:db8:ffff::1", false)]
#[case::nd_lookalike_port_to_the_internet(
    Side::Vm0,
    None,
    NEIGHBOR_SOLICIT_SPORT,
    "203.0.113.1",
    true
)]
#[case::solicit_lookalike_port_to_the_host_veth(
    Side::Vm0,
    None,
    NEIGHBOR_SOLICIT_SPORT,
    "10.200.0.1",
    false
)]
#[case::advert_lookalike_port_to_the_host_veth(
    Side::Vm0,
    None,
    NEIGHBOR_ADVERT_SPORT,
    "10.200.0.1",
    false
)]
#[case::solicit_lookalike_port_to_the_host_over_ipv6(
    Side::Vm0,
    None,
    NEIGHBOR_SOLICIT_SPORT,
    "2001:db8::2",
    false
)]
#[case::advert_lookalike_port_to_the_host_link_local(
    Side::Vm0,
    None,
    NEIGHBOR_ADVERT_SPORT,
    "fe80::1",
    false
)]
#[case::internet_to_another_vms_uplink(Side::Wan, None, 0, "10.200.0.6", false)]
fn a_hostile_vm_namespace_is_confined_as_root(
    #[case] from: Side,
    #[case] src: Option<&str>,
    #[case] sport: u16,
    #[case] to: &str,
    #[case] reachable: bool,
) {
    if !is_root() {
        eprintln!("SKIP hostile VM namespace: needs root");
        return;
    }
    let lab = Lab::new(&lab_name(&format!("nh-{from:?}-{sport}-{to}")), "");

    assert_eq!(lab.connects(from, src, sport, to), reachable);
}

#[rstest]
#[case::to_the_internet(0, "203.0.113.1", "wan", true)]
#[case::to_the_host_veth(0, "10.200.0.1", "host", false)]
#[case::to_a_host_address_off_the_uplink(0, "198.51.100.7", "host", false)]
#[case::to_the_host_veth_link_local(0, "fe80::1", "host", false)]
#[case::solicit_lookalike_port_to_the_host_veth(
    NEIGHBOR_SOLICIT_SPORT,
    "10.200.0.1",
    "host",
    false
)]
#[case::advert_lookalike_port_to_the_host_over_ipv6(
    NEIGHBOR_ADVERT_SPORT,
    "2001:db8::2",
    "host",
    false
)]
fn udp_from_a_vm_namespace_reaches_only_the_internet_as_root(
    #[case] sport: u16,
    #[case] to: &str,
    #[case] side: &str,
    #[case] delivered: bool,
) {
    if !is_root() {
        eprintln!("SKIP hostile VM namespace: needs root");
        return;
    }
    let lab = Lab::new(&lab_name(&format!("nu-{sport}-{to}")), "");

    assert_eq!(lab.datagram_arrives(sport, to, side), delivered);
}

#[rstest]
#[case::a_private_network_once_unblocked("10.9.0.1", true)]
#[case::its_host_veth("10.200.0.1", false)]
#[case::another_vms_uplink("10.200.0.6", false)]
#[case::the_host_uplink("203.0.113.2", false)]
#[case::the_hosts_own_node_prefix_address("2001:db8::2", false)]
fn with_nothing_blocked_a_vm_namespace_still_never_reaches_the_host_or_other_vms_as_root(
    #[case] to: &str,
    #[case] reachable: bool,
) {
    if !is_root() {
        eprintln!("SKIP hostile VM namespace: needs root");
        return;
    }
    let lab = Lab::new(&lab_name(&format!("nb-{to}")), "blocked = []\n");

    assert_eq!(lab.connects(Side::Vm0, None, 0, to), reachable);
}

#[rstest]
fn an_operator_blocked_ipv6_range_is_unreachable_from_a_vm_as_root() {
    if !is_root() {
        eprintln!("SKIP hostile VM namespace: needs root");
        return;
    }
    let lab = Lab::new("nb6", "blocked = [\"2001:db8:ffff::/48\"]\n");

    assert_eq!(
        (
            lab.connects(Side::Vm0, None, 0, "2001:db8:ffff::1"),
            lab.connects(Side::Vm0, None, 0, "203.0.113.1"),
        ),
        (false, true)
    );
}

#[rstest]
fn an_invalid_segment_from_the_internet_never_reaches_the_transit_range_as_root() {
    if !is_root() {
        eprintln!("SKIP hostile VM namespace: needs root");
        return;
    }
    let lab = Lab::new("ninv", "");

    assert_eq!(
        lab.invalid_segment_from_wan_reaches_vm0(Ipv4Addr::new(10, 200, 0, 2)),
        Vec::<Ipv4Addr>::new()
    );
}

fn firewall_table_in(ns: &NetNs) -> bool {
    ns.scoped(|| {
        Command::new("nft")
            .args(["list", "table", "inet", "hyper-firewall"])
            .output()
            .unwrap()
            .status
            .success()
    })
    .unwrap()
}

/// A file planted where `vm_firewall` looks for VM `id`'s namespace, removed on drop.
struct Pin(PathBuf);

impl Drop for Pin {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[rstest]
#[case::the_vms_own_namespace("namespace", true)]
#[case::plain_file("file", false)]
#[case::symlink_to_another_namespace("symlink", false)]
fn vm_firewall_acts_only_on_the_vms_own_namespace_as_root(
    #[case] kind: &str,
    #[case] applied: bool,
) {
    if !is_root() {
        eprintln!("SKIP vm_firewall pin: needs root");
        return;
    }
    let caller = ScratchNs::new(&format!("npin-{kind}-c"));
    let target = ScratchNs::new(&format!("npin-{kind}-t"));
    let id = match kind {
        "namespace" => {
            target.get().name().as_os_str().to_str().unwrap()["hyper-".len()..].to_owned()
        }
        _ => format!("npin{kind}{}", std::process::id()),
    };
    let _pin = (kind != "namespace").then(|| {
        let pin = Pin(Path::new("/run/netns").join(format!("hyper-{id}")));
        match kind {
            "file" => fs::write(&pin.0, "").unwrap(),
            _ => symlink(target.get().path().as_path(), &pin.0).unwrap(),
        }
        pin
    });
    let tmp = TempDir::new().unwrap();
    let cfg = tmp.path().join("config.toml");
    fs::write(&cfg, "work_dir = \"/srv/hyper\"\n").unwrap();
    fs::set_permissions(&cfg, fs::Permissions::from_mode(0o644)).unwrap();

    let out = caller.run(
        &cfg,
        json!({"op": "vm_firewall", "id": id, "firewall": {
            "inbound": [{"protocol": "tcp", "ports": [1, 65535]}], "outbound_blocked": []}}),
    );
    if !applied {
        out.code(2).stderr(contains("network namespace"));
    }

    assert_eq!(
        (
            firewall_table_in(caller.get()),
            firewall_table_in(target.get())
        ),
        (false, applied)
    );
}
