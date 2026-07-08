use hyper_suidhelper::tools::jailer::VmId;
use hyper_suidhelper::tools::network::addr::Plan;
use hyper_suidhelper::tools::network::args::{self, Which};
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
