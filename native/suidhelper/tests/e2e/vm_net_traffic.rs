//! Real connections across a whole node: `host_init`'s table on the host and `vm_launch`'s
//! namespaces, routes and tables for two VMs, with an internet (`wan`) beyond the uplink.
//!
//! Firecracker's `tap0` is swapped for a veth of the same name whose peer is the guest's
//! `eth0`, holding what `vm_launch` gave the tap, so every rule that matches on `tap0`
//! sees guest traffic. Laws, per the networking cookbook:
//! - the guest reaches the internet over IPv4 (double NAT) and IPv6 (routed /128);
//! - inbound, exactly the ports in the VM's open ranges reach it, both ends inclusive, for
//!   TCP and UDP alike;
//! - outbound, exactly the ports in its blocked ranges never leave it;
//! - VMs reach each other over their public IPv6 addresses only on the ports the
//!   receiving VM opened;
//! - DNS to the gateway reaches the resolver, and nothing else on the gateway answers;
//! - `vm_firewall` takes effect on the next connection.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use hyperrs_linux::net::link::DuplicateAddrDetection;
use hyperrs_linux::net::netns::NetNs;
use hyperrs_linux::net::route::Route;
use hyperrs_linux::net::{IfIndex, IfName, IpNet, Rtnl};
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::{json, Value};
use std::fs;
use std::net::{Ipv6Addr, SocketAddr, TcpListener, TcpStream, UdpSocket};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::thread;
use std::time::Duration;

mod support;
use socket2::{Domain, Protocol, Socket, Type};
use support::{is_root, MapperDevice, ScratchNs};

const RECORDER_EXIT: i32 = 7;
const DROPPED_AFTER: Duration = Duration::from_secs(2);
const GUEST_TCP: [u16; 4] = [6999, 7000, 7002, 7003];
const GUEST_UDP: [u16; 2] = [7100, 7101];
const WAN_TCP: [u16; 5] = [53, 7199, 7200, 7201, 7202];
/// Bound to one address each, so a reply leaves from the address the request reached.
const WAN_UDP: [&str; 3] = ["1.1.1.1:53", "198.51.100.1:7202", "[2001:db8:ffff::1]:7202"];

static LABS: AtomicU32 = AtomicU32::new(0);

#[derive(Debug, Clone, Copy)]
enum Vm {
    A,
    B,
}

impl Vm {
    fn net_id(self) -> u16 {
        match self {
            Self::A => 1,
            Self::B => 2,
        }
    }

    fn guest_v6(self) -> Ipv6Addr {
        Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 1, 0, 0, self.net_id())
    }

    fn firewall(self) -> Value {
        match self {
            Self::A => json!({
                "inbound": [
                    {"protocol": "tcp", "ports": [7000, 7002]},
                    {"protocol": "udp", "ports": [7100, 7100]},
                ],
                "outbound_blocked": [{"protocol": "tcp", "ports": [7200, 7201]}],
            }),
            Self::B => json!({
                "inbound": [{"protocol": "tcp", "ports": [7000, 7000]}],
                "outbound_blocked": [],
            }),
        }
    }
}

/// How the internet's router reaches the VM range.
#[derive(Debug, Clone, Copy)]
enum Upstream {
    /// Routed to the host's link-local address.
    Routed,
    /// On-link, so the router solicits each guest address and the host must answer by proxy.
    OnLink,
}

#[derive(Debug, Clone, Copy)]
enum Src {
    Guest(Vm),
    Wan,
}

#[derive(Debug, Clone, Copy)]
enum Proto {
    Tcp,
    Udp,
    /// An ICMP echo; the port is ignored.
    Ping,
}

struct Lab {
    host: ScratchNs,
    wan: ScratchNs,
    guests: [ScratchNs; 2],
    cfg: PathBuf,
    tag: u32,
    _tmp: TempDir,
    _rootfs: MapperDevice,
    _listeners: Vec<TcpListener>,
}

impl Drop for Lab {
    fn drop(&mut self) {
        for vm in [Vm::A, Vm::B] {
            let _ = NetNs::delete(self.netns(vm).as_str().try_into().unwrap());
        }
    }
}

impl Lab {
    fn new(upstream: Upstream) -> Option<Self> {
        if !is_root() {
            return None;
        }
        let tag = LABS.fetch_add(1, Ordering::Relaxed);
        let tmp = TempDir::new().unwrap();
        let base = fs::canonicalize(tmp.path()).unwrap();
        let work = base.join("srv");
        fs::create_dir_all(work.join("jails")).unwrap();
        let firecracker = base.join("firecracker");
        fs::write(&firecracker, "#!/bin/true\n").unwrap();
        let jailer = base.join("jailer");
        fs::copy(env!("CARGO_BIN_EXE_fake-jailer"), &jailer).unwrap();
        fs::set_permissions(&jailer, fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(work.join("vmlinux"), "kernel image").unwrap();
        let backing = base.join("rootfs.img");
        fs::write(&backing, vec![0u8; 1024 * 1024]).unwrap();
        let rootfs = MapperDevice::linear(
            &format!("hyper-e2e-traffic-{}-{tag}", std::process::id()),
            &backing,
        )?;
        let cfg = base.join("config.toml");
        fs::write(
            &cfg,
            format!(
                "work_dir = \"{}\"\n[tools]\njailer = \"{}\"\nfirecracker = \"{}\"\n\
                 [net]\nuplink = \"if0\"\nipv6_prefix = \"2001:db8::/64\"\n",
                work.display(),
                jailer.display(),
                firecracker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o644)).unwrap();

        let mut lab = Self {
            host: ScratchNs::new(&format!("traffic{tag}-host")),
            wan: ScratchNs::new(&format!("traffic{tag}-wan")),
            guests: [
                ScratchNs::new(&format!("traffic{tag}-ga")),
                ScratchNs::new(&format!("traffic{tag}-gb")),
            ],
            cfg,
            tag,
            _tmp: tmp,
            _rootfs: rootfs,
            _listeners: Vec::new(),
        };
        lab.wire_the_internet(upstream);
        lab.host.run(&lab.cfg, json!({"op": "host_init"})).success();
        for vm in [Vm::A, Vm::B] {
            let launched = lab.host.run(
                &lab.cfg,
                json!({
                    "op": "vm_launch",
                    "id": lab.id(vm),
                    "uid": 900_001,
                    "gid": 900_002,
                    "kernel": work.join("vmlinux"),
                    "device": lab._rootfs.path(),
                    "limits": {},
                    "net_id": vm.net_id(),
                    "firewall": vm.firewall(),
                }),
            );
            assert_eq!(launched.get_output().status.code(), Some(RECORDER_EXIT));
            lab.plug_in_the_guest(vm);
        }

        let tcp = |ns: &ScratchNs, port| {
            ns.get()
                .scoped(|| TcpListener::bind((Ipv6Addr::UNSPECIFIED, port)))
                .unwrap()
                .unwrap()
        };
        let echo = |ns: &ScratchNs, at: SocketAddr| {
            let socket = ns.get().scoped(|| UdpSocket::bind(at)).unwrap().unwrap();
            thread::spawn(move || {
                let mut buf = [0u8; 64];
                while let Ok((n, from)) = socket.recv_from(&mut buf) {
                    let _ = socket.send_to(&buf[..n], from);
                }
            });
        };
        let mut listeners: Vec<TcpListener> = WAN_TCP.iter().map(|p| tcp(&lab.wan, *p)).collect();
        WAN_UDP
            .iter()
            .for_each(|at| echo(&lab.wan, at.parse().unwrap()));
        for (guest, vm) in lab.guests.iter().zip([Vm::A, Vm::B]) {
            listeners.extend(GUEST_TCP.iter().map(|p| tcp(guest, *p)));
            GUEST_UDP
                .iter()
                .for_each(|p| echo(guest, guest_port(vm, *p)));
        }
        lab._listeners = listeners;
        Some(lab)
    }

    fn id(&self, vm: Vm) -> String {
        format!("vm{}t{}{vm:?}", std::process::id(), self.tag).to_lowercase()
    }

    fn netns(&self, vm: Vm) -> String {
        format!("hyper-{}", self.id(vm))
    }

    fn guest(&self, vm: Vm) -> &NetNs {
        match vm {
            Vm::A => self.guests[0].get(),
            Vm::B => self.guests[1].get(),
        }
    }

    fn wire_the_internet(&self, upstream: Upstream) {
        let host = self.host.get().rtnl().unwrap();
        let wan = self.wan.get().rtnl().unwrap();
        host.create_veth(&name("if0"), &name("wan"), self.wan.get())
            .unwrap();
        up(&host, "lo", &[]);
        let if0 = up(&host, "if0", &["203.0.113.2/24", "fe80::a/64"]);
        up(
            &wan,
            "lo",
            &["198.51.100.1/32", "1.1.1.1/32", "2001:db8:ffff::1/128"],
        );
        let wan_link = up(&wan, "wan", &["203.0.113.1/24", "fe80::b/64"]);
        let vm_range = match upstream {
            Upstream::Routed => route("2001:db8:0:0:1::/80", Some("fe80::a"), wan_link),
            Upstream::OnLink => route("2001:db8::/64", None, wan_link),
        };
        for (rtnl, route) in [
            (&host, route("0.0.0.0/0", Some("203.0.113.1"), if0)),
            (&host, route("::/0", Some("fe80::b"), if0)),
            (&wan, vm_range),
        ] {
            rtnl.add_route(&route).unwrap();
        }
        self.host.get().enable_forwarding().unwrap();
    }

    fn plug_in_the_guest(&self, vm: Vm) {
        let ns = NetNs::open(self.netns(vm).as_str().try_into().unwrap()).unwrap();
        let inner = ns.rtnl().unwrap();
        inner
            .link(&name("tap0"))
            .unwrap()
            .unwrap()
            .delete()
            .unwrap();
        inner
            .create_veth(&name("tap0"), &name("eth0"), self.guest(vm))
            .unwrap();
        let tap = up(&inner, "tap0", &["172.16.0.1/30", "fe80::1/64"]);
        inner
            .add_route(&route(&format!("{}/128", vm.guest_v6()), None, tap))
            .unwrap();

        let guest = self.guest(vm).rtnl().unwrap();
        up(&guest, "lo", &[]);
        let eth0 = up(
            &guest,
            "eth0",
            &[
                "172.16.0.2/30",
                &format!("{}/128", vm.guest_v6()),
                "fe80::2/64",
            ],
        );
        for (dst, via) in [("0.0.0.0/0", "172.16.0.1"), ("::/0", "fe80::1")] {
            guest.add_route(&route(dst, Some(via), eth0)).unwrap();
        }
    }

    fn set_firewall(&self, vm: Vm, firewall: Value) {
        self.host
            .run(
                &self.cfg,
                json!({"op": "vm_firewall", "id": self.id(vm), "firewall": firewall}),
            )
            .success();
    }

    fn reaches(&self, from: Src, proto: Proto, to: SocketAddr) -> bool {
        let ns = match from {
            Src::Guest(vm) => self.guest(vm),
            Src::Wan => self.wan.get(),
        };
        match proto {
            Proto::Tcp => ns
                .scoped(|| TcpStream::connect_timeout(&to, DROPPED_AFTER).is_ok())
                .unwrap(),
            Proto::Udp => {
                let local: SocketAddr = match to {
                    SocketAddr::V4(_) => "0.0.0.0:0".parse().unwrap(),
                    SocketAddr::V6(_) => "[::]:0".parse().unwrap(),
                };
                let socket = ns.scoped(|| UdpSocket::bind(local)).unwrap().unwrap();
                socket.set_read_timeout(Some(DROPPED_AFTER)).unwrap();
                socket.send_to(b"ping", to).unwrap();
                let mut buf = [0u8; 64];
                socket
                    .recv_from(&mut buf)
                    .is_ok_and(|(n, _)| &buf[..n] == b"ping")
            }
            Proto::Ping => ns.scoped(|| pings(to)).unwrap(),
        }
    }
}

/// Whether an echo request to `to` gets its reply back.
fn pings(to: SocketAddr) -> bool {
    const ID: u16 = 0x4859;
    let (domain, protocol, request, reply) = match to {
        SocketAddr::V4(_) => (Domain::IPV4, Protocol::ICMPV4, 8, 0),
        SocketAddr::V6(_) => (Domain::IPV6, Protocol::ICMPV6, 128, 129),
    };
    let socket = Socket::new(domain, Type::RAW, Some(protocol)).unwrap();
    socket.set_read_timeout(Some(DROPPED_AFTER)).unwrap();
    let mut echo = [request, 0, 0, 0, (ID >> 8) as u8, ID as u8, 0, 1];
    if matches!(to, SocketAddr::V4(_)) {
        let sum = echo
            .chunks(2)
            .map(|w| u32::from(u16::from_be_bytes([w[0], w[1]])))
            .sum::<u32>();
        echo[2..4].copy_from_slice(&(!(((sum & 0xffff) + (sum >> 16)) as u16)).to_be_bytes());
    }
    let target = SocketAddr::new(to.ip(), 0);
    socket.send_to(&echo, &target.into()).unwrap();
    let mut packet = [0u8; 1500];
    while let Ok(n) = std::io::Read::read(&mut &socket, &mut packet) {
        let icmp = match to {
            SocketAddr::V4(_) => &packet[usize::from(packet[0] & 0x0f) * 4..n],
            SocketAddr::V6(_) => &packet[..n],
        };
        if icmp.len() >= 8 && icmp[0] == reply && u16::from_be_bytes([icmp[4], icmp[5]]) == ID {
            return true;
        }
    }
    false
}

fn name(s: &str) -> IfName {
    s.parse().unwrap()
}

fn up(rtnl: &Rtnl, link: &str, addrs: &[&str]) -> IfIndex {
    let link = rtnl.link(&name(link)).unwrap().unwrap();
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

fn guest_port(vm: Vm, port: u16) -> SocketAddr {
    SocketAddr::from((vm.guest_v6(), port))
}

macro_rules! require {
    ($upstream:expr) => {
        match Lab::new($upstream) {
            Some(lab) => lab,
            None => {
                eprintln!("SKIP: needs root and losetup/dmsetup");
                return;
            }
        }
    };
}

#[rstest]
#[case::guest_to_the_internet_over_ipv4(Src::Guest(Vm::A), Proto::Tcp, "198.51.100.1:7202", true)]
#[case::guest_to_the_internet_over_ipv6(
    Src::Guest(Vm::A),
    Proto::Tcp,
    "[2001:db8:ffff::1]:7202",
    true
)]
#[case::below_the_blocked_range(Src::Guest(Vm::A), Proto::Tcp, "198.51.100.1:7199", true)]
#[case::first_blocked_port(Src::Guest(Vm::A), Proto::Tcp, "198.51.100.1:7200", false)]
#[case::last_blocked_port(Src::Guest(Vm::A), Proto::Tcp, "198.51.100.1:7201", false)]
#[case::blocked_over_ipv6(Src::Guest(Vm::A), Proto::Tcp, "[2001:db8:ffff::1]:7200", false)]
#[case::another_vm_blocks_nothing(Src::Guest(Vm::B), Proto::Tcp, "198.51.100.1:7200", true)]
#[case::below_the_open_range(Src::Wan, Proto::Tcp, "[2001:db8::1:0:0:1]:6999", false)]
#[case::first_open_port(Src::Wan, Proto::Tcp, "[2001:db8::1:0:0:1]:7000", true)]
#[case::last_open_port(Src::Wan, Proto::Tcp, "[2001:db8::1:0:0:1]:7002", true)]
#[case::above_the_open_range(Src::Wan, Proto::Tcp, "[2001:db8::1:0:0:1]:7003", false)]
#[case::open_udp_port(Src::Wan, Proto::Udp, "[2001:db8::1:0:0:1]:7100", true)]
#[case::closed_udp_port(Src::Wan, Proto::Udp, "[2001:db8::1:0:0:1]:7101", false)]
#[case::tcp_rule_opens_no_udp(Src::Wan, Proto::Udp, "[2001:db8::1:0:0:2]:7100", false)]
#[case::vm_to_vm_on_an_open_port(Src::Guest(Vm::A), Proto::Tcp, "[2001:db8::1:0:0:2]:7000", true)]
#[case::vm_to_vm_on_a_closed_port(Src::Guest(Vm::A), Proto::Tcp, "[2001:db8::1:0:0:2]:7003", false)]
#[case::vm_to_vm_over_the_transit_range(Src::Guest(Vm::A), Proto::Tcp, "10.200.0.10:7000", false)]
#[case::udp_to_the_internet_over_ipv4(Src::Guest(Vm::A), Proto::Udp, "198.51.100.1:7202", true)]
#[case::udp_to_the_internet_over_ipv6(
    Src::Guest(Vm::A),
    Proto::Udp,
    "[2001:db8:ffff::1]:7202",
    true
)]
#[case::dns_over_udp_reaches_the_resolver(Src::Guest(Vm::A), Proto::Udp, "172.16.0.1:53", true)]
#[case::ping_to_the_internet_over_ipv4(Src::Guest(Vm::A), Proto::Ping, "198.51.100.1:0", true)]
#[case::ping_to_the_internet_over_ipv6(
    Src::Guest(Vm::A),
    Proto::Ping,
    "[2001:db8:ffff::1]:0",
    true
)]
#[case::inbound_ping_is_not_an_open_port(Src::Wan, Proto::Ping, "[2001:db8::1:0:0:1]:0", false)]
#[case::the_gateway_does_not_answer_ping(Src::Guest(Vm::A), Proto::Ping, "172.16.0.1:0", false)]
#[case::dns_over_tcp_reaches_the_resolver(Src::Guest(Vm::A), Proto::Tcp, "172.16.0.1:53", true)]
#[case::other_gateway_ports_are_silent(Src::Guest(Vm::A), Proto::Tcp, "172.16.0.1:7202", false)]
#[case::guest_to_the_host_uplink(Src::Guest(Vm::A), Proto::Tcp, "203.0.113.2:7202", false)]
fn a_launched_node_carries_exactly_what_the_cookbook_allows_as_root(
    #[case] from: Src,
    #[case] proto: Proto,
    #[case] to: &str,
    #[case] reachable: bool,
) {
    let lab = require!(Upstream::Routed);

    assert_eq!(lab.reaches(from, proto, to.parse().unwrap()), reachable);
}

#[rstest]
fn a_new_firewall_governs_the_next_connection_as_root() {
    let lab = require!(Upstream::Routed);
    let before =
        [7000, 7003].map(|port| lab.reaches(Src::Wan, Proto::Tcp, guest_port(Vm::A, port)));

    lab.set_firewall(
        Vm::A,
        json!({"inbound": [{"protocol": "tcp", "ports": [7003, 7003]}], "outbound_blocked": []}),
    );

    assert_eq!(
        (
            before,
            [7000, 7003].map(|port| lab.reaches(Src::Wan, Proto::Tcp, guest_port(Vm::A, port))),
            lab.reaches(
                Src::Guest(Vm::A),
                Proto::Tcp,
                "198.51.100.1:7200".parse().unwrap()
            ),
        ),
        ([true, false], [false, true], true)
    );
}

#[rstest]
#[case::open_port(7000, true)]
#[case::closed_port(7003, false)]
fn an_on_link_upstream_reaches_a_guest_through_proxy_ndp_as_root(
    #[case] port: u16,
    #[case] reachable: bool,
) {
    let lab = require!(Upstream::OnLink);

    assert_eq!(
        lab.reaches(Src::Wan, Proto::Tcp, guest_port(Vm::B, port)),
        reachable
    );
}
