use hyper_suidhelper::config::Network;
use hyper_suidhelper::tools::jailer::VmId;
use hyper_suidhelper::tools::network::addr::Plan;
use hyper_suidhelper::tools::network::args::{self, Which};
use hyper_suidhelper::tools::network::{prepare, resolve_network, NetworkingDisabled};
use std::net::Ipv4Addr;
use std::str::FromStr;

fn plan0() -> Plan {
    Plan::derive(
        900_000,
        (900_000, 999_999),
        Ipv4Addr::new(172, 31, 0, 0),
        &VmId::from_str("vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").unwrap(),
    )
    .unwrap()
}

#[test]
fn prepare_creates_netns_first_and_default_route_last() {
    let cmds = args::prepare_commands(&plan0(), "/usr/sbin/nft", "/usr/sbin/sysctl");
    let first = &cmds[0];
    assert!(matches!(first.bin, Which::Ip));
    assert_eq!(
        first.argv,
        vec!["netns", "add", "vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
    );
    // The default route (guest reachability) must come after the veth is up.
    let route_idx = cmds
        .iter()
        .position(|c| c.argv.contains(&"default".to_string()))
        .unwrap();
    let veth_up_idx = cmds
        .iter()
        .position(|c| c.argv == vec!["link", "set", "hv0", "up"])
        .unwrap();
    assert!(route_idx > veth_up_idx);
}

#[test]
fn teardown_deletes_netns() {
    let cmds = args::teardown_commands(&plan0());
    assert!(cmds
        .iter()
        .any(|c| c.argv == vec!["netns", "del", "vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]));
}

#[test]
fn teardown_orphan_is_exactly_ip_netns_del_by_id_alone() {
    // No uid, no veth cleanup: an orphan's teardown has only the vm_id to work
    // from (see `teardown_orphan`'s module doc), and `ip netns del` alone is
    // sufficient to reclaim the veth peer, TAP, and in-netns nftables state.
    let cmds = args::teardown_orphan_commands("vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    assert_eq!(
        cmds,
        vec![cmd(
            Which::Ip,
            &["netns", "del", "vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]
        )]
    );
}

#[test]
fn host_init_masquerades_pool_out_uplink() {
    let cmds = args::host_init_commands("eth0", "172.31.0.0/16");
    assert!(cmds.iter().any(
        |c| c.argv.contains(&"masquerade".to_string()) && c.argv.contains(&"eth0".to_string())
    ));
    // metadata IP is dropped
    assert!(cmds
        .iter()
        .any(|c| c.argv.contains(&"169.254.169.254".to_string())));
}

#[test]
fn host_init_drops_guest_traffic_to_host() {
    // The INPUT hook is a distinct chain from FORWARD: a guest packet
    // addressed to a host-owned IP (its own gateway, or any other host IP) is
    // locally delivered, never forwarded, so without an explicit input-chain
    // drop a guest could reach host-local services (epmd, distribution,
    // Postgres, gRPC) regardless of the forward-chain policy. Pinned as its
    // own assertion so a future edit to the forward chain can't silently drop
    // this isolation.
    let cmds = args::host_init_commands("eth0", "172.31.0.0/16");
    assert!(cmds.iter().any(|c| c.bin == Which::Nft
        && c.argv.contains(&"input".to_string())
        && c.argv.contains(&"saddr".to_string())
        && c.argv.contains(&"172.31.0.0/16".to_string())
        && c.argv.contains(&"drop".to_string())));
}

fn cmd(bin: Which, argv: &[&str]) -> args::Command {
    args::Command {
        bin,
        argv: argv.iter().map(|s| s.to_string()).collect(),
        allow_failure: false,
    }
}

fn cmd_allow_failure(bin: Which, argv: &[&str]) -> args::Command {
    args::Command {
        allow_failure: true,
        ..cmd(bin, argv)
    }
}

/// Full-sequence golden test: pins every bin/argv, in order, so a wrong flag,
/// a wrong address, or a reordered/reversed SNAT/DNAT target fails here even
/// though it would slip past the substring checks above.
#[test]
fn prepare_commands_golden_sequence() {
    let netns = "vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    // In-netns nft runs via `ip netns exec <ns> <abs nft path>` — the absolute
    // path, since the helper clears PATH before spawning (see nft_ns).
    let nft = "/usr/sbin/nft";
    let sysctl = "/usr/sbin/sysctl";
    let cmds = args::prepare_commands(&plan0(), nft, sysctl);
    let expected = vec![
        cmd(Which::Ip, &["netns", "add", netns]),
        cmd(
            Which::Ip,
            &["link", "add", "hv0", "type", "veth", "peer", "name", "hp0"],
        ),
        cmd(Which::Ip, &["link", "set", "hp0", "netns", netns]),
        cmd(Which::Ip, &["addr", "add", "172.31.0.1/30", "dev", "hv0"]),
        cmd(Which::Ip, &["link", "set", "hv0", "up"]),
        cmd(
            Which::Ip,
            &["-n", netns, "addr", "add", "172.31.0.2/30", "dev", "hp0"],
        ),
        cmd(Which::Ip, &["-n", netns, "link", "set", "hp0", "up"]),
        cmd(
            Which::Ip,
            &["-n", netns, "tuntap", "add", "tap0", "mode", "tap"],
        ),
        cmd(
            Which::Ip,
            &["-n", netns, "addr", "add", "172.30.0.1/30", "dev", "tap0"],
        ),
        cmd(Which::Ip, &["-n", netns, "link", "set", "tap0", "up"]),
        cmd(Which::Ip, &["-n", netns, "link", "set", "lo", "up"]),
        cmd(
            Which::Ip,
            &["-n", netns, "route", "add", "default", "via", "172.31.0.1"],
        ),
        cmd(
            Which::Ip,
            &[
                "netns",
                "exec",
                netns,
                sysctl,
                "-w",
                "net.ipv4.ip_forward=1",
            ],
        ),
        cmd(
            Which::Ip,
            &["netns", "exec", netns, nft, "add", "table", "ip", "nat"],
        ),
        cmd(
            Which::Ip,
            &[
                "netns",
                "exec",
                netns,
                nft,
                "add",
                "chain",
                "ip",
                "nat",
                "post",
                "{",
                "type",
                "nat",
                "hook",
                "postrouting",
                "priority",
                "100",
                ";",
                "}",
            ],
        ),
        cmd(
            Which::Ip,
            &[
                "netns",
                "exec",
                netns,
                nft,
                "add",
                "rule",
                "ip",
                "nat",
                "post",
                "ip",
                "saddr",
                "172.30.0.2",
                "oifname",
                "hp0",
                "snat",
                "to",
                "172.31.0.2",
            ],
        ),
        cmd(
            Which::Ip,
            &[
                "netns",
                "exec",
                netns,
                nft,
                "add",
                "chain",
                "ip",
                "nat",
                "pre",
                "{",
                "type",
                "nat",
                "hook",
                "prerouting",
                "priority",
                "-100",
                ";",
                "}",
            ],
        ),
        cmd(
            Which::Ip,
            &[
                "netns",
                "exec",
                netns,
                nft,
                "add",
                "rule",
                "ip",
                "nat",
                "pre",
                "ip",
                "daddr",
                "172.31.0.2",
                "dnat",
                "to",
                "172.30.0.2",
            ],
        ),
    ];
    assert_eq!(cmds, expected);
}

/// Full-sequence golden test for the host-init nftables program: pins the
/// leading, failure-tolerant `delete table` (the reconcile-to-desired-state
/// step — see `host_init.rs`'s module doc), the metadata-IP drop rule
/// immediately after the forward chain is created and before the broad
/// egress accept (since `accept` is a terminating verdict in nftables and a
/// drop reachable only after it would never fire), the catch-all pool drop
/// rules after the egress and established/related accepts (so unrelated
/// forwarded traffic — notably Docker bridge — falls through via `policy
/// accept` while pool traffic is still isolated), the trailing input-chain
/// isolation (drops all clone-pool-sourced traffic addressed to the host
/// itself, on the INPUT hook FORWARD never sees — see `host_init_commands`'s
/// doc), and that every command after the delete is *not* failure-tolerant.
#[test]
fn host_init_commands_golden_sequence() {
    let cmds = args::host_init_commands("eth0", "172.31.0.0/16");
    let expected = vec![
        cmd_allow_failure(Which::Nft, &["delete", "table", "ip", "hyper"]),
        cmd(Which::Nft, &["add", "table", "ip", "hyper"]),
        cmd(
            Which::Nft,
            &[
                "add",
                "chain",
                "ip",
                "hyper",
                "postrouting",
                "{",
                "type",
                "nat",
                "hook",
                "postrouting",
                "priority",
                "100",
                ";",
                "}",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add",
                "rule",
                "ip",
                "hyper",
                "postrouting",
                "ip",
                "saddr",
                "172.31.0.0/16",
                "oifname",
                "eth0",
                "masquerade",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add", "chain", "ip", "hyper", "forward", "{", "type", "filter", "hook", "forward",
                "priority", "0", ";", "policy", "accept", ";", "}",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add",
                "rule",
                "ip",
                "hyper",
                "forward",
                "ip",
                "saddr",
                "172.31.0.0/16",
                "ip",
                "daddr",
                "169.254.169.254",
                "drop",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add",
                "rule",
                "ip",
                "hyper",
                "forward",
                "ip",
                "saddr",
                "172.31.0.0/16",
                "oifname",
                "eth0",
                "accept",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add",
                "rule",
                "ip",
                "hyper",
                "forward",
                "ip",
                "daddr",
                "172.31.0.0/16",
                "ct",
                "state",
                "established,related",
                "accept",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add", "rule", "ip", "hyper", "forward", "ip", "saddr", "172.31.0.0/16", "drop",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add", "rule", "ip", "hyper", "forward", "ip", "daddr", "172.31.0.0/16", "drop",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add", "chain", "ip", "hyper", "input", "{", "type", "filter", "hook", "input",
                "priority", "0", ";", "policy", "accept", ";", "}",
            ],
        ),
        cmd(
            Which::Nft,
            &[
                "add",
                "rule",
                "ip",
                "hyper",
                "input",
                "ip",
                "saddr",
                "172.31.0.0/16",
                "drop",
            ],
        ),
    ];
    assert_eq!(cmds, expected);
}

#[test]
fn prepare_refuses_uid_outside_range() {
    // Derivation from an out-of-range uid must error before any command runs.
    // Proving `Err` here is sufficient, not just necessary, to prove no
    // privileged command spawns: `plan_from` only ever returns a `Plan`, and
    // every op derives its commands from that returned `Plan` in a separate
    // step downstream, one that is structurally unreachable when derivation
    // itself fails.
    let err = prepare::plan_from(
        42,
        (900_000, 999_999),
        "172.31.0.0/16",
        &VmId::from_str("vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").unwrap(),
    );
    assert!(err.is_err());
}

#[test]
fn prepare_refuses_malformed_clone_pool_cidr() {
    // A malformed CIDR must error before any command runs, distinctly from a
    // uid-range refusal.
    let err = prepare::plan_from(
        900_000,
        (900_000, 999_999),
        "not-a-cidr",
        &VmId::from_str("vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").unwrap(),
    );
    assert!(err.is_err());
}

#[test]
fn resolve_network_refuses_when_networking_disabled() {
    // `[network]` absent from config is the security-critical refusal: every
    // op (`prepare`, `teardown`, `host_init`) resolves through this same pure
    // function before spawning anything privileged, so this exercises the
    // real refusal path, not a copy of it — no root and no config file
    // needed, since it takes the already-resolved `Option<&Network>` rather
    // than reaching into `Config` itself.
    assert!(matches!(resolve_network(None), Err(NetworkingDisabled)));
}

#[test]
fn resolve_network_returns_the_configured_network_when_present() {
    let network = Network {
        uplink: Some("eth0".to_string()),
        clone_pool: "172.31.0.0/16".to_string(),
    };
    let resolved = resolve_network(Some(&network)).unwrap();
    assert_eq!(resolved.uplink.as_deref(), Some("eth0"));
    assert_eq!(resolved.clone_pool, "172.31.0.0/16");
}

#[test]
fn host_init_forward_chain_uses_policy_accept() {
    // Regression: the forward chain must use `policy accept` so that traffic
    // unrelated to the clone pool (e.g. Docker bridge traffic between
    // containers) falls through to other chains on the forward hook. A
    // `policy drop` would silently drop all forwarded traffic not explicitly
    // accepted by *this* chain, breaking colocated Docker networking.
    let cmds = args::host_init_commands("eth0", "172.31.0.0/16");
    let forward_chain = cmds
        .iter()
        .find(|c| {
            c.bin == Which::Nft
                && c.argv.contains(&"chain".to_string())
                && c.argv.contains(&"forward".to_string())
        })
        .expect("forward chain command must exist");
    let policy_idx = forward_chain
        .argv
        .iter()
        .position(|a| a == "policy")
        .expect("forward chain must have a policy");
    assert_eq!(
        forward_chain.argv[policy_idx + 1], "accept",
        "forward chain policy must be accept, not drop"
    );
}
