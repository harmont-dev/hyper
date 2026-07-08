use hyper_suidhelper::tools::jailer::VmId;
use hyper_suidhelper::tools::network::addr::Plan;
use hyper_suidhelper::tools::network::args::{self, Which};
use hyper_suidhelper::tools::network::prepare;
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
    let cmds = args::prepare_commands(&plan0());
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

fn cmd(bin: Which, argv: &[&str]) -> args::Command {
    args::Command {
        bin,
        argv: argv.iter().map(|s| s.to_string()).collect(),
    }
}

/// Full-sequence golden test: pins every bin/argv, in order, so a wrong flag,
/// a wrong address, or a reordered/reversed SNAT/DNAT target fails here even
/// though it would slip past the substring checks above.
#[test]
fn prepare_commands_golden_sequence() {
    let netns = "vaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    let cmds = args::prepare_commands(&plan0());
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
            &["netns", "exec", netns, "nft", "add", "table", "ip", "nat"],
        ),
        cmd(
            Which::Ip,
            &[
                "netns",
                "exec",
                netns,
                "nft",
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
                "nft",
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
                "nft",
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
                "nft",
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
/// metadata-IP drop rule immediately after the forward chain is created and
/// before the broad egress accept, since `accept` is a terminating verdict in
/// nftables and a drop reachable only after it would never fire.
#[test]
fn host_init_commands_golden_sequence() {
    let cmds = args::host_init_commands("eth0", "172.31.0.0/16");
    let expected = vec![
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
                "priority", "0", ";", "policy", "drop", ";", "}",
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
    ];
    assert_eq!(cmds, expected);
}

#[test]
fn prepare_refuses_uid_outside_range() {
    // Derivation from an out-of-range uid must error before any command runs.
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
