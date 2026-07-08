use hyper_suidhelper::config::{Config, Network};

#[test]
fn absent_network_table_means_disabled() {
    // Default config (no file) has no [network] table.
    let cfg = Config::default();
    assert!(cfg.network().is_none());
}

#[test]
fn present_table_with_only_uplink_defaults_clone_pool() {
    // clone_pool is safety-critical: it must match Elixir's
    // Hyper.Cfg.Network.clone_pool/0 default. This is the present-path test —
    // it fails if this default ever drifts from the Elixir literal.
    let network: Network = toml::from_str("uplink = \"eth0\"\n").expect("valid TOML");
    assert_eq!(network.clone_pool, "172.31.0.0/16");
}
