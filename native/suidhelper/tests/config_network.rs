//! Contract: VM networking is unimplemented pending a rewrite, but operator
//! configs written before it must keep loading. A legacy `[network]` table and
//! `[tools] ip`/`nft`/`sysctl` keys are accepted and ignored. `Config` is a
//! process-wide `LazyLock` that exits the helper on any parse failure, so
//! rejecting these keys would brick every tool, not just networking.
use hyper_suidhelper::config::Config;

#[test]
fn legacy_network_keys_are_accepted_and_ignored() {
    let toml_str = "\
work_dir = \"/srv/hyper\"
[tools]
ip = \"/usr/bin/ip\"
nft = \"/usr/sbin/nft\"
sysctl = \"/usr/sbin/sysctl\"
[network]
uplink = \"eth0\"
clone_pool = \"172.31.0.0/16\"
resolver = \"1.1.1.1\"
";
    let config: Config = toml::from_str(toml_str).expect("legacy networking keys must parse");
    assert_eq!(config.hyper_base(), std::path::Path::new("/srv/hyper"));
}
