use hyper_suidhelper::config::Config;
use rstest::rstest;
use std::path::Path;

fn parse(work_dir: &str) -> Result<Config, toml::de::Error> {
    toml::from_str(&format!("work_dir = {work_dir:?}\n"))
}

#[rstest]
fn non_strict_work_dir_is_refused_at_load(
    #[values(
        "relative/path",
        "/srv/../etc",
        "/srv/./hyper",
        "/srv//hyper",
        "/srv/hyper/",
        ""
    )]
    work_dir: &str,
) {
    assert!(parse(work_dir).is_err(), "{work_dir:?} accepted");
}

#[rstest]
fn bases_derive_from_work_dir() {
    let config = parse("/data/hyper").unwrap();
    assert_eq!(config.hyper_base().as_path(), Path::new("/data/hyper"));
    assert_eq!(config.jail_base().as_path(), Path::new("/data/hyper/jails"));
}

#[rstest]
fn non_component_parent_cgroup_is_refused_at_load(
    #[values("", ".", "..", "a/b", "/hyper", "hyper/")] cgroup: &str,
) {
    let body = format!("work_dir = \"/srv/hyper\"\n[jails]\ncgroup = {cgroup:?}\n");
    assert!(
        toml::from_str::<Config>(&body).is_err(),
        "{cgroup:?} accepted"
    );
}

#[rstest]
fn parent_cgroup_dir_is_under_the_cgroup_root() {
    let config: Config =
        toml::from_str("work_dir = \"/srv/hyper\"\n[jails]\ncgroup = \"vms\"\n").unwrap();
    assert_eq!(
        config.parent_cgroup_dir().as_path(),
        Path::new("/sys/fs/cgroup/vms")
    );
}
