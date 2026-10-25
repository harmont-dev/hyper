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

#[test]
fn partial_network_table_without_uplink_disables_not_bricks() {
    // A `[network]` table with `clone_pool` set but `uplink` omitted must
    // parse the WHOLE config successfully (not fail the process-wide,
    // exit-on-error `Config` load that every subcommand — dmsetup, losetup,
    // chroot-jail, jailer, not just networking — depends on) and must resolve
    // to networking-disabled, mirroring Elixir's Hyper.Cfg.Network.enabled?/0
    // (uplink absent ⇒ disabled, not an error).
    let toml_str = "work_dir = \"/srv/hyper\"\n[network]\nclone_pool = \"10.0.0.0/8\"\n";
    let config: Config = toml::from_str(toml_str).expect("a partial [network] table must parse");
    assert!(config.network().is_none());
}
