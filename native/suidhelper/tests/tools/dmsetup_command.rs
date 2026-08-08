//! `create` promises the caller `/dev/mapper/<name>`, so that node must exist by
//! the time the command returns — the very next `create` in an image chain names
//! it as a table device, and the kernel resolves that path when it loads the
//! table.
//!
//! Whether libdevmapper creates the node itself or defers to udev depends on the
//! environment: with udev in charge, the node appears out-of-band. Inside a
//! container (how Citrus deploys) the helper's `dmsetup` cannot sync with the
//! host's udev — the sync uses SysV semaphores, which are IPC-namespaced — so
//! the node is never created and the next table load fails with
//! `reload ioctl ... failed: No such file or directory`.
//!
//! `DM_DISABLE_UDEV` takes udev out of the decision entirely: libdevmapper
//! creates the nodes itself, on bare metal and in a container alike.

use clap::Parser;
use hyper_suidhelper::tools::{Dmsetup, DmsetupArgs};
use std::ffi::OsStr;
use std::path::PathBuf;

#[derive(Parser)]
struct Cli {
    #[command(flatten)]
    args: DmsetupArgs,
}

fn dmsetup(argv: &[&str]) -> Dmsetup {
    let mut full = vec!["dmsetup"];
    full.extend_from_slice(argv);
    let cli = Cli::try_parse_from(full).expect("args should parse");
    Dmsetup::new(PathBuf::from("/usr/sbin/dmsetup"), cli.args)
}

fn env_of(d: &Dmsetup) -> Vec<(String, Option<String>)> {
    d.command()
        .get_envs()
        .map(|(k, v)| {
            (
                k.to_string_lossy().into_owned(),
                v.map(|v| v.to_string_lossy().into_owned()),
            )
        })
        .collect()
}

#[test]
fn create_disables_udev_so_the_device_node_is_created_by_the_library() {
    let d = dmsetup(&[
        "create",
        "hyper-img-pad-abc",
        "--readonly",
        "--table",
        "0 100 snapshot /dev/loop0 /dev/loop1 P 8",
    ]);

    assert!(
        env_of(&d).contains(&("DM_DISABLE_UDEV".to_string(), Some("1".to_string()))),
        "create must set DM_DISABLE_UDEV=1 so /dev/mapper/<name> exists when it returns; env was {:?}",
        env_of(&d)
    );
}

#[test]
fn every_op_runs_with_a_cleared_environment_plus_the_udev_opt_out() {
    // The helper is setuid: it must not inherit the caller's environment. The
    // udev opt-out is the one variable it adds back.
    for argv in [
        vec!["remove", "--retry", "hyper-img-abc-1"],
        vec!["ls"],
        vec!["targets"],
        vec!["suspend", "hyper-rw-abc"],
    ] {
        let env = env_of(&dmsetup(&argv));
        assert_eq!(
            env,
            vec![("DM_DISABLE_UDEV".to_string(), Some("1".to_string()))],
            "unexpected environment for {argv:?}"
        );
    }
}

#[test]
fn create_still_passes_name_readonly_and_table_through() {
    let d = dmsetup(&[
        "create",
        "hyper-img-abc-1",
        "--readonly",
        "--table",
        "0 100 snapshot /dev/loop0 /dev/loop1 P 8",
    ]);

    let cmd = d.command();
    let argv: Vec<&OsStr> = cmd.get_args().collect();
    assert_eq!(
        argv,
        vec![
            OsStr::new("create"),
            OsStr::new("hyper-img-abc-1"),
            OsStr::new("--readonly"),
            OsStr::new("--table"),
            OsStr::new("0 100 snapshot /dev/loop0 /dev/loop1 P 8"),
        ]
    );
}
