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
use hyperrs_linux::net::{IfName, IpNet, Ipv4Net, Rtnl};
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::json;
use std::fs;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::time::Duration;

mod support;
use support::{is_root, ScratchNs};

const PORT: u16 = 7070;
const DROPPED_AFTER: Duration = Duration::from_millis(500);

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
        Self::up(&host, "vm-veth-0", &["10.200.0.1/30"]);
        Self::up(
            &host,
            "if0",
            &["203.0.113.2/24", "10.9.0.2/24", "169.254.0.2/16"],
        );
        let uplink = Self::up(&vm, "uplink", &["10.200.0.2/30"]);
        vm.add_route(&Self::v4_route("0.0.0.0/0", "10.200.0.1", uplink))
            .unwrap();
        let wan_link = Self::up(
            &wan,
            "wan",
            &["203.0.113.1/24", "10.9.0.1/24", "169.254.169.254/16"],
        );
        wan.add_route(&Self::v4_route("10.200.0.0/16", "203.0.113.2", wan_link))
            .unwrap();

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

    fn connects(&self, from: Side, to: Ipv4Addr) -> bool {
        self.ns(from)
            .scoped(|| {
                TcpStream::connect_timeout(&SocketAddr::from((to, PORT)), DROPPED_AFTER).is_ok()
            })
            .unwrap()
    }

    fn up(rtnl: &Rtnl, link: &str, addrs: &[&str]) -> hyperrs_linux::net::IfIndex {
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

    fn v4_route(dst: &str, via: &str, dev: hyperrs_linux::net::IfIndex) -> Route {
        let IpNet::V4(dst) = dst.parse::<IpNet>().unwrap() else {
            unreachable!("{dst} is IPv4")
        };
        Route::V4 {
            dst: Ipv4Net {
                addr: dst.network(),
                prefix: dst.prefix,
            },
            via: Some(via.parse().unwrap()),
            dev,
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
#[case::internet_to_the_vm(Side::Wan, "10.200.0.2", true)]
fn the_host_firewall_confines_vms_as_root(
    #[case] from: Side,
    #[case] to: &str,
    #[case] reachable: bool,
) {
    if !is_root() {
        eprintln!("SKIP host firewall: needs root");
        return;
    }
    let lab = Lab::new(&format!("fw-{from:?}-{to}").to_lowercase().replace('.', "-"));

    assert_eq!(lab.connects(from, to.parse().unwrap()), reachable);
}
