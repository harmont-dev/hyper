//! L4 for the jailer handoff: prove the exact argv (and an EMPTY environment) the
//! helper hands to the jailer via `execve`, and that the jailer's exit status
//! propagates. We point the config's `jailer` at a root-owned recorder that
//! writes its argv and its `/proc/self/environ` to files, then exits with a known
//! code. Root-only: `become_root_permanently` requires we are already root.
#![cfg(feature = "insecure_mode")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

mod support;
use support::{is_root, run};

const RECORDER_EXIT: i32 = 7;

fn install_recorder(dir: &Path) -> PathBuf {
    let path = dir.join("jailer");
    fs::copy(env!("CARGO_BIN_EXE_fake-jailer"), &path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// A root-owned plain file with basename `firecracker` — the `--exec-file`. It is
/// never executed by us (the jailer would), only validated as a `RootSafeBinPathBuf`.
fn install_firecracker(dir: &Path) -> PathBuf {
    let path = dir.join("firecracker");
    fs::write(&path, b"#!/bin/true\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    path
}

fn write_root_config(dir: &Path, jailer: &Path, firecracker: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    let body = format!(
        "work_dir = \"/srv/hyper\"\n[tools]\njailer = \"{}\"\nfirecracker = \"{}\"\n",
        jailer.display(),
        firecracker.display(),
    );
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

/// Same as [`write_root_config`] plus a legacy `[network]` table and
/// `[tools] ip`/`nft`/`sysctl` keys, as an operator config written before the
/// networking rewrite would carry.
fn write_root_config_with_legacy_network(dir: &Path, jailer: &Path, firecracker: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    let body = format!(
        "work_dir = \"/srv/hyper\"\n[tools]\njailer = \"{}\"\nfirecracker = \"{}\"\nip = \"/usr/bin/ip\"\nnft = \"/usr/sbin/nft\"\nsysctl = \"/usr/sbin/sysctl\"\n[network]\nuplink = \"eth0\"\nclone_pool = \"172.31.0.0/16\"\n",
        jailer.display(),
        firecracker.display(),
    );
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

#[test]
fn execs_jailer_with_canonical_argv_and_empty_env_as_root() {
    if !is_root() {
        eprintln!("SKIP jailer exec: needs root to become_root_permanently + own the fakes");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let argv_rec = tmp.path().join("argv.json");
    let env_rec = tmp.path().join("environ.bin");
    let jailer = install_recorder(tmp.path());
    let firecracker = install_firecracker(tmp.path());
    let cfg = write_root_config(tmp.path(), &jailer, &firecracker);

    let out = run(
        &cfg,
        &[
            "jailer",
            "--id",
            "vm1",
            "--uid",
            "900001",
            "--gid",
            "900002",
            "--memory-max",
            "1048576",
            "--cpu-quota-us",
            "100000",
            "--cpu-period-us",
            "100000",
            "--api-sock",
            "/api.sock",
        ],
    );

    // The jailer's own exit status must propagate through the execve handoff.
    out.code(RECORDER_EXIT);

    let argv: Vec<String> =
        serde_json::from_str(&fs::read_to_string(&argv_rec).expect("recorded argv")).unwrap();
    assert_eq!(
        argv,
        vec![
            "--id",
            "vm1",
            "--exec-file",
            &firecracker.to_string_lossy(),
            "--uid",
            "900001",
            "--gid",
            "900002",
            "--chroot-base-dir",
            "/srv/hyper/jails",
            "--cgroup-version",
            "2",
            "--parent-cgroup",
            "hyper",
            "--cgroup",
            "memory.max=1048576",
            "--cgroup",
            "cpu.max=100000 100000",
            "--",
            "--api-sock",
            "/api.sock",
        ],
        "helper handed the jailer a non-canonical argv",
    );

    // The helper execve's the jailer with an EMPTY envp (see src/tools/jailer.rs):
    // once ruid==0 a smuggled LD_PRELOAD would be honored, so nothing of the
    // caller's environment may reach the root jailer. The recorder is a `/bin/sh`
    // script and the shell *self-sets* `PWD` (and, under bash, `_`/`SHLVL`) on
    // startup, so a literally-empty environ is impossible to observe through it.
    // We instead prove no CALLER variable survives: the helper is spawned with
    // `HYPER_*` config vars in its own environment (see `run`), so their absence
    // here is the leak canary - had the helper passed its environment through,
    // they would appear alongside `PWD`.
    let environ = fs::read(&env_rec).expect("recorded environ");
    let leaked: Vec<String> = environ
        .split(|&b| b == 0)
        .filter(|entry| !entry.is_empty())
        .map(|entry| String::from_utf8_lossy(entry).into_owned())
        .filter(|entry| {
            let key = entry.split('=').next().unwrap_or("");
            !matches!(key, "PWD" | "_" | "SHLVL")
        })
        .collect();
    assert!(
        leaked.is_empty(),
        "caller environment leaked to the jailer (only shell-set PWD/_/SHLVL allowed): {leaked:?}",
    );
}

#[test]
fn execs_jailer_without_netns_with_legacy_network_table_as_root() {
    if !is_root() {
        eprintln!(
            "SKIP jailer legacy [network]: needs root to become_root_permanently + own the fakes"
        );
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let argv_rec = tmp.path().join("argv.json");
    let jailer = install_recorder(tmp.path());
    let firecracker = install_firecracker(tmp.path());
    let cfg = write_root_config_with_legacy_network(tmp.path(), &jailer, &firecracker);

    let out = run(
        &cfg,
        &[
            "jailer",
            "--id",
            "vnet1",
            "--uid",
            "900001",
            "--gid",
            "900002",
            "--api-sock",
            "/api.sock",
        ],
    );

    out.code(RECORDER_EXIT);

    let argv: Vec<String> =
        serde_json::from_str(&fs::read_to_string(&argv_rec).expect("recorded argv")).unwrap();
    assert!(
        !argv.iter().any(|a| a == "--netns"),
        "the jailer must never be told to enter a netns: {argv:?}"
    );
}

#[test]
fn refuses_uid_zero_without_exec_as_root() {
    if !is_root() {
        eprintln!("SKIP jailer uid 0: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let argv_rec = tmp.path().join("argv.json");
    let jailer = install_recorder(tmp.path());
    let firecracker = install_firecracker(tmp.path());
    let cfg = write_root_config(tmp.path(), &jailer, &firecracker);

    run(
        &cfg,
        &[
            "jailer",
            "--id",
            "vm1",
            "--uid",
            "0",
            "--gid",
            "900002",
            "--api-sock",
            "/api.sock",
        ],
    )
    .code(2);
    assert!(
        !argv_rec.exists(),
        "the jailer must never have been exec'd for uid 0",
    );
}
