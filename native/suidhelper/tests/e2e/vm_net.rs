//! The network `vm_launch` builds and `vm_teardown` removes, observed from a scratch host
//! namespace with `ip` and `nft` rather than the helper's own rtnetlink code.
//!
//! Laws:
//! - teardown removes everything a launch added to the host: the `vm-veth-<id>`, the
//!   guest's `/128` route, its proxy-NDP entry and the VM's namespace; a second teardown
//!   changes nothing;
//! - tearing one VM down leaves every other VM's network as it was;
//! - a relaunch replaces the VM's previous network, whatever NetId it held;
//! - a launch that fails while networking (a NetId another VM holds, a missing uplink)
//!   leaves no network of its own behind and never damages the VM holding the NetId;
//! - teardown without `[net]` still unlinks the VM, and the next teardown with `[net]`
//!   sweeps the proxy entry it could not find;
//! - helpers launching and tearing down distinct VMs at once end in exactly the network
//!   of the VMs left running;
//! - `vm_firewall` replaces the port policy whole and leaves the namespace's own table be;
//! - a policy at the per-direction cap, on the edge ports, is one `nft` accepts.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::net::Ipv6Addr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};

mod support;
use hyperrs_linux::net::netns::NetNs;
use support::{is_root, MapperDevice, ScratchNs};

const RECORDER_EXIT: i32 = 7;
const REFUSED_EXIT: i32 = 2;
const NODE_PREFIX: &str = "2001:db8::/64";

static HOSTS: AtomicU32 = AtomicU32::new(0);

/// The cookbook's VM address for `net_id`, `<prefix>:1:0:0:<net_id>`.
fn guest(net_id: u16) -> Ipv6Addr {
    Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 1, 0, 0, net_id)
}

#[derive(Debug, Default, PartialEq, Eq)]
struct HostNet {
    veths: BTreeSet<String>,
    guest_routes: BTreeSet<Ipv6Addr>,
    proxies: BTreeSet<Ipv6Addr>,
}

impl HostNet {
    fn of(vms: &[u16]) -> Self {
        Self {
            veths: vms.iter().map(|id| format!("vm-veth-{id}")).collect(),
            guest_routes: vms.iter().copied().map(guest).collect(),
            proxies: vms.iter().copied().map(guest).collect(),
        }
    }
}

struct Host {
    ns: ScratchNs,
    tmp: TempDir,
    work: PathBuf,
    firecracker: PathBuf,
    jailer: PathBuf,
    kernel: PathBuf,
    rootfs: MapperDevice,
    tag: u32,
}

impl Drop for Host {
    fn drop(&mut self) {
        let Ok(entries) = fs::read_dir("/run/netns") else {
            return;
        };
        let mine = format!("hyper-vm{}x{}", std::process::id(), self.tag);
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with(&mine) {
                let _ = NetNs::delete(name.as_str().try_into().unwrap());
            }
        }
    }
}

impl Host {
    fn new() -> Option<Self> {
        if !is_root() {
            return None;
        }
        let tmp = TempDir::new().unwrap();
        let base = fs::canonicalize(tmp.path()).unwrap();
        let work = base.join("srv");
        fs::create_dir_all(work.join("jails")).unwrap();
        let firecracker = base.join("firecracker");
        fs::write(&firecracker, "#!/bin/true\n").unwrap();
        let jailer = base.join("jailer");
        fs::copy(env!("CARGO_BIN_EXE_fake-jailer"), &jailer).unwrap();
        fs::set_permissions(&jailer, fs::Permissions::from_mode(0o755)).unwrap();
        let kernel = work.join("vmlinux-src");
        fs::write(&kernel, "kernel image").unwrap();
        let backing = base.join("rootfs.img");
        fs::write(&backing, vec![0u8; 1024 * 1024]).unwrap();
        let tag = HOSTS.fetch_add(1, Ordering::Relaxed);
        let rootfs = MapperDevice::linear(
            &format!("hyper-e2e-vmnet-{}-{tag}", std::process::id()),
            &backing,
        )?;
        Some(Self {
            ns: ScratchNs::new(&format!("vmnet{tag}")),
            tmp,
            work,
            firecracker,
            jailer,
            kernel,
            rootfs,
            tag,
        })
    }

    fn id(&self, vm: &str) -> String {
        format!("vm{}x{}{vm}", std::process::id(), self.tag)
    }

    fn config(&self, net: Option<&str>) -> PathBuf {
        let p = self
            .tmp
            .path()
            .join(format!("config-{}.toml", net.unwrap_or("none")));
        let net = net.map_or(String::new(), |uplink| {
            format!("[net]\nuplink = \"{uplink}\"\nipv6_prefix = \"{NODE_PREFIX}\"\n")
        });
        let body = format!(
            "work_dir = \"{}\"\n[tools]\njailer = \"{}\"\nfirecracker = \"{}\"\n{net}",
            self.work.display(),
            self.jailer.display(),
            self.firecracker.display(),
        );
        fs::write(&p, body).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
        p
    }

    fn launch(&self, cfg: &Path, vm: &str, net_id: u16, firewall: Value) -> i32 {
        let request = json!({
            "op": "vm_launch",
            "id": self.id(vm),
            "uid": 900_001,
            "gid": 900_002,
            "kernel": self.kernel,
            "device": self.rootfs.path(),
            "limits": {},
            "net_id": net_id,
            "firewall": firewall,
        });
        self.ns
            .run(cfg, request)
            .get_output()
            .status
            .code()
            .unwrap()
    }

    /// Run every request at once, each in its own helper, and return their exit codes.
    fn concurrently(&self, cfg: &Path, requests: &[Value]) -> Vec<i32> {
        let children: Vec<_> = requests
            .iter()
            .map(|request| {
                self.ns
                    .get()
                    .scoped(|| {
                        support::command(cfg, &[&request.to_string()])
                            .stdout(Stdio::null())
                            .stderr(Stdio::piped())
                            .spawn()
                            .unwrap()
                    })
                    .unwrap()
            })
            .collect();
        children
            .into_iter()
            .map(|child| {
                let out = child.wait_with_output().unwrap();
                out.status.code().unwrap()
            })
            .collect()
    }

    fn launch_request(&self, vm: &str, net_id: u16) -> Value {
        json!({
            "op": "vm_launch",
            "id": self.id(vm),
            "uid": 900_001,
            "gid": 900_002,
            "kernel": self.kernel,
            "device": self.rootfs.path(),
            "limits": {},
            "net_id": net_id,
            "firewall": open(),
        })
    }

    fn teardown(&self, cfg: &Path, vm: &str) {
        self.ns
            .run(cfg, json!({"op": "vm_teardown", "id": self.id(vm)}))
            .success();
    }

    fn has_netns(&self, vm: &str) -> bool {
        Path::new("/run/netns")
            .join(format!("hyper-{}", self.id(vm)))
            .exists()
    }

    fn ip(&self, args: &[&str]) -> Value {
        let out = self
            .ns
            .get()
            .scoped(|| Command::new("ip").args(args).output().unwrap())
            .unwrap();
        assert!(out.status.success(), "ip {args:?}: {out:?}");
        let stdout = String::from_utf8(out.stdout).unwrap();
        if stdout.trim().is_empty() {
            return json!([]);
        }
        serde_json::from_str(&stdout).unwrap()
    }

    fn observe(&self) -> HostNet {
        let in_vm_range = |addr: Ipv6Addr| u128::from(addr) >> 48 == u128::from(guest(0)) >> 48;
        let addrs = |listing: Value, key: &str| -> BTreeSet<Ipv6Addr> {
            listing
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|entry| entry[key].as_str())
                .filter_map(|dst| dst.split('/').next().unwrap().parse().ok())
                .filter(|addr| in_vm_range(*addr))
                .collect()
        };
        HostNet {
            veths: self
                .ip(&["-j", "link", "show"])
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|link| link["ifname"].as_str())
                .filter(|name| name.starts_with("vm-veth-"))
                .map(str::to_owned)
                .collect(),
            guest_routes: addrs(self.ip(&["-j", "-6", "route", "show"]), "dst"),
            proxies: addrs(self.ip(&["-j", "-6", "neigh", "show", "proxy"]), "dst"),
        }
    }

    fn nft_rules(&self, vm: &str, table: &str) -> Option<Vec<Value>> {
        let ns = NetNs::open(
            format!("hyper-{}", self.id(vm))
                .as_str()
                .try_into()
                .unwrap(),
        )
        .ok()?;
        let out = ns
            .scoped(|| {
                Command::new("nft")
                    .args(["-j", "list", "table", "inet", table])
                    .output()
                    .unwrap()
            })
            .unwrap();
        if !out.status.success() {
            return None;
        }
        let listing: Value = serde_json::from_slice(&out.stdout).unwrap();
        Some(
            listing["nftables"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|item| item.get("rule"))
                .map(|rule| rule["expr"].clone())
                .collect(),
        )
    }

    /// Every destination-port match in `table`, as `(protocol, first, last)`.
    fn dports(&self, vm: &str, table: &str) -> Vec<(String, u64, u64)> {
        self.nft_rules(vm, table)
            .expect("the table is listed")
            .iter()
            .flat_map(|expr| expr.as_array().unwrap().clone())
            .filter_map(|statement| {
                let m = statement.get("match")?;
                let payload = m["left"].get("payload")?;
                (payload["field"] == "dport").then(|| {
                    let protocol = payload["protocol"].as_str().unwrap().to_owned();
                    match &m["right"] {
                        Value::Number(port) => {
                            (protocol, port.as_u64().unwrap(), port.as_u64().unwrap())
                        }
                        range => (
                            protocol,
                            range["range"][0].as_u64().unwrap(),
                            range["range"][1].as_u64().unwrap(),
                        ),
                    }
                })
            })
            .collect()
    }
}

fn open() -> Value {
    json!({"inbound": [], "outbound_blocked": []})
}

macro_rules! require {
    () => {
        match Host::new() {
            Some(host) => host,
            None => {
                eprintln!("SKIP: needs root and losetup/dmsetup");
                return;
            }
        }
    };
}

#[rstest]
#[case::first(0)]
#[case::past_one_octet(64)]
#[case::last(16_383)]
fn teardown_leaves_no_trace_of_the_vm_network_and_is_idempotent_as_root(#[case] net_id: u16) {
    let host = require!();
    let cfg = host.config(Some("lo"));

    assert_eq!(host.launch(&cfg, "a", net_id, open()), RECORDER_EXIT);
    let launched = (host.observe(), host.has_netns("a"));
    host.teardown(&cfg, "a");
    let torn_down = (host.observe(), host.has_netns("a"));
    host.teardown(&cfg, "a");

    assert_eq!(
        (launched, torn_down, (host.observe(), host.has_netns("a"))),
        (
            (HostNet::of(&[net_id]), true),
            (HostNet::default(), false),
            (HostNet::default(), false),
        )
    );
}

#[rstest]
fn tearing_one_vm_down_leaves_its_neighbours_network_alone_as_root() {
    let host = require!();
    let cfg = host.config(Some("lo"));

    for (vm, net_id) in [("a", 1), ("b", 2), ("c", 3)] {
        assert_eq!(host.launch(&cfg, vm, net_id, open()), RECORDER_EXIT);
    }
    host.teardown(&cfg, "b");

    assert_eq!(
        (host.observe(), ["a", "b", "c"].map(|vm| host.has_netns(vm))),
        (HostNet::of(&[1, 3]), [true, false, true])
    );
}

#[rstest]
fn a_relaunch_onto_another_net_id_replaces_the_old_network_as_root() {
    let host = require!();
    let cfg = host.config(Some("lo"));

    assert_eq!(host.launch(&cfg, "a", 1, open()), RECORDER_EXIT);
    assert_eq!(host.launch(&cfg, "a", 2, open()), RECORDER_EXIT);

    assert_eq!(host.observe(), HostNet::of(&[2]));
}

#[rstest]
fn a_launch_onto_a_held_net_id_fails_and_leaves_the_holder_intact_as_root() {
    let host = require!();
    let cfg = host.config(Some("lo"));

    assert_eq!(host.launch(&cfg, "a", 5, open()), RECORDER_EXIT);
    let refused = host.launch(&cfg, "b", 5, open());

    assert_eq!(
        (
            refused,
            host.observe(),
            host.has_netns("a"),
            host.has_netns("b")
        ),
        (REFUSED_EXIT, HostNet::of(&[5]), true, false)
    );
}

#[rstest]
fn a_launch_whose_uplink_is_missing_leaves_no_network_behind_as_root() {
    let host = require!();
    let cfg = host.config(Some("nope0"));

    let refused = host.launch(&cfg, "a", 4, open());

    assert_eq!(
        (refused, host.observe(), host.has_netns("a")),
        (REFUSED_EXIT, HostNet::default(), false)
    );
}

#[rstest]
fn a_teardown_without_net_config_unlinks_and_the_next_one_sweeps_its_proxy_as_root() {
    let host = require!();
    let (with_net, without_net) = (host.config(Some("lo")), host.config(None));

    assert_eq!(host.launch(&with_net, "a", 6, open()), RECORDER_EXIT);
    assert_eq!(host.launch(&with_net, "b", 7, open()), RECORDER_EXIT);
    host.teardown(&without_net, "a");
    let unswept = host.observe();
    host.teardown(&with_net, "never-launched");

    assert_eq!(
        (unswept, host.observe(), host.has_netns("a")),
        (
            HostNet {
                proxies: [guest(6), guest(7)].into(),
                ..HostNet::of(&[7])
            },
            HostNet::of(&[7]),
            false
        )
    );
}

#[rstest]
fn setting_the_firewall_replaces_the_policy_whole_and_keeps_the_namespace_table_as_root() {
    let host = require!();
    let cfg = host.config(Some("lo"));
    let launched_with = json!({
        "inbound": [{"protocol": "tcp", "ports": [22, 22]}],
        "outbound_blocked": [{"protocol": "tcp", "ports": [25, 25]}],
    });
    assert_eq!(host.launch(&cfg, "a", 8, launched_with), RECORDER_EXIT);
    let namespace_table = host.nft_rules("a", "hyper");

    host.ns
        .run(
            &cfg,
            json!({"op": "vm_firewall", "id": host.id("a"), "firewall": {
                "inbound": [{"protocol": "udp", "ports": [6000, 6010]}],
                "outbound_blocked": [],
            }}),
        )
        .success();

    assert_eq!(
        (
            host.dports("a", "hyper-firewall"),
            host.nft_rules("a", "hyper") == namespace_table,
        ),
        (vec![("udp".to_owned(), 6000, 6010)], true)
    );
}

#[rstest]
fn a_policy_at_the_rule_cap_on_the_edge_ports_is_installed_whole_as_root() {
    let host = require!();
    let cfg = host.config(Some("lo"));
    let edges = [[1, 1], [65_535, 65_535], [1, 65_535]];
    let rules = |protocol: &str| -> Vec<(String, u64, u64)> {
        edges
            .iter()
            .map(|[first, last]| (*first, *last))
            .chain((0..125).map(|i| (1000 + 2 * i, 1001 + 2 * i)))
            .map(|(first, last)| (protocol.to_owned(), first, last))
            .collect()
    };
    let request = |rules: &[(String, u64, u64)]| -> Vec<Value> {
        rules
            .iter()
            .map(|(protocol, first, last)| json!({"protocol": protocol, "ports": [first, last]}))
            .collect()
    };
    let (inbound, outbound) = (rules("tcp"), rules("udp"));

    let launched = host.launch(
        &cfg,
        "a",
        9,
        json!({"inbound": request(&inbound), "outbound_blocked": request(&outbound)}),
    );

    assert_eq!(
        (launched, host.dports("a", "hyper-firewall")),
        (RECORDER_EXIT, [inbound, outbound].concat())
    );
}

#[rstest]
fn concurrent_launches_and_teardowns_end_in_exactly_the_running_vms_network_as_root() {
    let host = require!();
    let cfg = host.config(Some("lo"));
    let first: Vec<(String, u16)> = (0..6).map(|i| (format!("a{i}"), 10 + i)).collect();
    let second: Vec<(String, u16)> = (0..6).map(|i| (format!("b{i}"), 20 + i)).collect();

    let launched = host.concurrently(
        &cfg,
        &first
            .iter()
            .map(|(vm, net_id)| host.launch_request(vm, *net_id))
            .collect::<Vec<_>>(),
    );
    let mixed = host.concurrently(
        &cfg,
        &first
            .iter()
            .step_by(2)
            .map(|(vm, _)| json!({"op": "vm_teardown", "id": host.id(vm)}))
            .chain(
                second
                    .iter()
                    .map(|(vm, net_id)| host.launch_request(vm, *net_id)),
            )
            .collect::<Vec<_>>(),
    );
    let running: Vec<u16> = first
        .iter()
        .skip(1)
        .step_by(2)
        .chain(&second)
        .map(|(_, net_id)| *net_id)
        .collect();

    assert_eq!(
        (launched, mixed, host.observe()),
        (
            vec![RECORDER_EXIT; 6],
            [vec![0; 3], vec![RECORDER_EXIT; 6]].concat(),
            HostNet::of(&running)
        )
    );
}
