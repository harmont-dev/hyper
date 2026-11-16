//! The #156 caller gate, end to end through the built binary: privileged ops run only for root
//! and members of the group the helper file belongs to.
//!
//! Each case installs a copy of the helper `root:<group>` mode 0711, so a non-root caller cannot
//! read it and the kernel execs it non-dumpable, as it would a setuid binary, and runs it under an
//! exact uid, primary gid and supplementary list. The probe op is `vm_claim_api_socket`: once
//! past the gate its first act is raising euid, which a non-setuid copy cannot do, so a caller
//! the gate let through fails with `raising euid` and touches nothing.
//!
//! Laws:
//! - a non-root caller passes iff the install group is its primary gid or anywhere among its
//!   supplementary gids;
//! - the refusal comes before the config is opened: a refused caller learns nothing about it,
//!   while an admitted caller is the one who meets the config checks;
//! - `version` answers anyone and never reads the config;
//! - the gate keys on the inode that runs, not the path it was invoked by;
//! - root is admitted whatever its gids, even beside a root install group.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use nix::unistd::{chown, setgroups, setresgid, setresuid, Gid, Uid};
use pretty_assertions::assert_eq;
use proptest::prelude::*;
use rstest::rstest;
use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use test_strategy::proptest;

mod support;
use support::{is_root, BIN};

const NOBODY: u32 = 65_534;
const NODE: u32 = 54_321;
const PROBE: &str = r#"{"op":"vm_claim_api_socket","id":"vgate"}"#;
const PAST_THE_GATE: &str = "raising euid to root";
const NOT_IN_GROUP: &str = "is not in the helper's group";

struct Install {
    dir: TempDir,
    bin: PathBuf,
}

impl Install {
    fn new(group: u32) -> Self {
        let dir = TempDir::new().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        let bin = dir.path().join("hyper-suidhelper");
        fs::copy(BIN, &bin).unwrap();
        chown(&bin, Some(Uid::from_raw(0)), Some(Gid::from_raw(group))).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o711)).unwrap();
        Self { dir, bin }
    }

    fn config(&self, body: &str, owner: u32) -> PathBuf {
        let path = self.dir.path().join("config.toml");
        fs::write(&path, body).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        chown(
            &path,
            Some(Uid::from_raw(owner)),
            Some(Gid::from_raw(owner)),
        )
        .unwrap();
        path
    }

    fn absent_config(&self) -> PathBuf {
        self.dir.path().join("absent.toml")
    }
}

fn run_as(bin: &Path, config: &Path, uid: u32, gid: u32, groups: &[u32], request: &str) -> Output {
    let groups: Vec<Gid> = groups.iter().copied().map(Gid::from_raw).collect();
    let mut cmd = Command::new(bin);
    cmd.arg(request)
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config)
        .current_dir("/");
    // SAFETY: the hook runs in the forked child before exec and only makes id syscalls.
    unsafe {
        cmd.pre_exec(move || {
            let (gid, uid) = (Gid::from_raw(gid), Uid::from_raw(uid));
            setgroups(&groups)?;
            setresgid(gid, gid, gid)?;
            setresuid(uid, uid, uid)?;
            Ok(())
        });
    }
    cmd.output().unwrap()
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

fn gids() -> impl Strategy<Value = u32> {
    prop_oneof![
        Just(0u32),
        Just(NOBODY),
        1u32..60_000,
        60_000u32..4_000_000_000
    ]
    .prop_filter("not the node group", |&g| g != NODE)
}

#[proptest(cases = 24)]
fn a_caller_passes_iff_it_holds_the_install_group_as_root(
    #[strategy(gids())] primary: u32,
    #[strategy(proptest::collection::vec(gids(), 0..64))] mut groups: Vec<u32>,
    member: bool,
    at: usize,
) {
    if !is_root() {
        eprintln!("SKIP caller gate property: needs root to install the helper and switch ids");
        return Ok(());
    }
    if member {
        groups.insert(at % (groups.len() + 1), NODE);
    }
    let install = Install::new(NODE);

    let out = run_as(
        &install.bin,
        &install.absent_config(),
        NOBODY,
        primary,
        &groups,
        PROBE,
    );

    let stderr = stderr(&out);
    prop_assert_eq!(out.status.code(), Some(2), "{}", stderr);
    if member {
        prop_assert!(stderr.contains(PAST_THE_GATE), "member refused: {}", stderr);
    } else {
        prop_assert!(
            stderr.contains(NOT_IN_GROUP),
            "non-member admitted: {}",
            stderr
        );
        prop_assert!(
            stderr.contains(&format!("uid {NOBODY} ")) && stderr.contains(&NODE.to_string()),
            "{}",
            stderr
        );
    }
}

const UNTRUSTED_CONFIG: &str = "not owned by root:root";

#[rstest]
#[case::a_non_member_is_refused_without_seeing_the_config(&[], NOT_IN_GROUP, UNTRUSTED_CONFIG)]
#[case::a_member_is_the_one_who_meets_the_config_check(&[NODE], UNTRUSTED_CONFIG, PAST_THE_GATE)]
fn the_gate_refuses_before_the_config_is_opened_as_root(
    #[case] groups: &[u32],
    #[case] refusal: &str,
    #[case] unreached: &str,
) {
    if !is_root() {
        eprintln!("SKIP gate-before-config: needs root");
        return;
    }
    let install = Install::new(NODE);
    let untrusted = install.config("work_dir = \"/srv/hyper\"\n", NOBODY);

    let out = run_as(&install.bin, &untrusted, NOBODY, NOBODY, groups, PROBE);

    let stderr = stderr(&out);
    assert_eq!(out.status.code(), Some(2), "{stderr}");
    assert!(stderr.contains(refusal), "{stderr}");
    assert!(!stderr.contains(unreached), "{stderr}");
}

#[rstest]
#[case::untrusted_config(true)]
#[case::malformed_config(false)]
fn version_answers_a_non_member_without_reading_the_config_as_root(#[case] untrusted: bool) {
    if !is_root() {
        eprintln!("SKIP version for non-members: needs root");
        return;
    }
    let install = Install::new(NODE);
    let config = if untrusted {
        install.config("work_dir = \"/srv/hyper\"\n", NOBODY)
    } else {
        install.config("this is = not = toml", 0)
    };

    let out = run_as(
        &install.bin,
        &config,
        NOBODY,
        NOBODY,
        &[],
        r#"{"op":"version"}"#,
    );

    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let report: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(report["version"], env!("CARGO_PKG_VERSION"));
}

#[rstest]
#[case::member(&[NODE], PAST_THE_GATE)]
#[case::non_member(&[], NOT_IN_GROUP)]
fn the_gate_keys_on_the_running_inode_not_the_invoked_path_as_root(
    #[case] groups: &[u32],
    #[case] expected: &str,
) {
    if !is_root() {
        eprintln!("SKIP gate via symlink: needs root");
        return;
    }
    let install = Install::new(NODE);
    let elsewhere = TempDir::new().unwrap();
    fs::set_permissions(elsewhere.path(), fs::Permissions::from_mode(0o755)).unwrap();
    let link = elsewhere.path().join("hyper-suidhelper");
    symlink(&install.bin, &link).unwrap();
    chown(
        elsewhere.path(),
        Some(Uid::from_raw(NOBODY)),
        Some(Gid::from_raw(NOBODY)),
    )
    .unwrap();

    let out = run_as(
        &link,
        &install.absent_config(),
        NOBODY,
        NOBODY,
        groups,
        PROBE,
    );

    assert!(stderr(&out).contains(expected), "{}", stderr(&out));
}

#[rstest]
#[case::root_install_group(0)]
#[case::node_install_group(NODE)]
fn root_is_admitted_whatever_its_gids_as_root(#[case] group: u32) {
    if !is_root() {
        eprintln!("SKIP root bypass: needs root");
        return;
    }
    let install = Install::new(group);

    let out = run_as(
        &install.bin,
        &install.absent_config(),
        0,
        NOBODY,
        &[NOBODY],
        PROBE,
    );

    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply, json!({"result": "pending"}));
}
