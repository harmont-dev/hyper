use hyper_suidhelper::config::Config;

#[test]
fn absent_network_table_means_disabled() {
    // Default config (no file) has no [network] table.
    let cfg = Config::default();
    assert!(cfg.network().is_none());
}
