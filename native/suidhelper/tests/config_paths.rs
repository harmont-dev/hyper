use hyper_suidhelper::config::Config;
use std::path::Path;

fn parse(work_dir: &str) -> Result<Config, toml::de::Error> {
    toml::from_str(&format!("work_dir = {work_dir:?}\n"))
}

#[test]
fn non_strict_work_dir_is_refused_at_load() {
    for work_dir in [
        "relative/path",
        "/srv/../etc",
        "/srv/./hyper",
        "/srv//hyper",
        "/srv/hyper/",
        "",
    ] {
        assert!(parse(work_dir).is_err(), "{work_dir:?} accepted");
    }
}

#[test]
fn bases_derive_from_work_dir() {
    let config = parse("/data/hyper").unwrap();
    assert_eq!(config.hyper_base().as_path(), Path::new("/data/hyper"));
    assert_eq!(config.jail_base().as_path(), Path::new("/data/hyper/jails"));
}

#[test]
fn non_component_parent_cgroup_is_refused_at_load() {
    for cgroup in ["", ".", "..", "a/b", "/hyper", "hyper/"] {
        let body = format!("work_dir = \"/srv/hyper\"\n[jails]\ncgroup = {cgroup:?}\n");
        assert!(
            toml::from_str::<Config>(&body).is_err(),
            "{cgroup:?} accepted"
        );
    }
}

#[test]
fn parent_cgroup_dir_is_under_the_cgroup_root() {
    let config: Config =
        toml::from_str("work_dir = \"/srv/hyper\"\n[jails]\ncgroup = \"vms\"\n").unwrap();
    assert_eq!(
        config.parent_cgroup_dir().as_path(),
        Path::new("/sys/fs/cgroup/vms")
    );
}
