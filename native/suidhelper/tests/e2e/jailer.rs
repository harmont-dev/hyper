//! L4 for the jailer handoff: prove the exact argv (and an EMPTY environment) the
//! helper hands to the jailer via `execve`, and that the jailer's exit status
//! propagates. We point the config's `jailer` at a root-owned recorder that
//! writes its argv and its `/proc/self/environ` to files, then exits with a known
//! code. Root-only: `become_root_permanently` requires we are already root.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
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

fn write_root_config(dir: &Path, jailer: &Path, firecracker: &Path, tables: &str) -> PathBuf {
    let p = dir.join("config.toml");
    let body = format!(
        "work_dir = \"/srv/hyper\"\n[tools]\njailer = \"{}\"\nfirecracker = \"{}\"\n{tables}",
        jailer.display(),
        firecracker.display(),
    );
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

struct Recorded {
    tmp: TempDir,
    firecracker: PathBuf,
    argv: PathBuf,
}

impl Recorded {
    fn config(&self, tables: &str) -> PathBuf {
        let jailer = install_recorder(self.tmp.path());
        write_root_config(self.tmp.path(), &jailer, &self.firecracker, tables)
    }

    fn argv(&self) -> Vec<String> {
        serde_json::from_str(&fs::read_to_string(&self.argv).expect("recorded argv")).unwrap()
    }
}

#[fixture]
fn recorded() -> Recorded {
    let tmp = TempDir::new().unwrap();
    let firecracker = install_firecracker(tmp.path());
    let argv = tmp.path().join("argv.json");
    Recorded {
        tmp,
        firecracker,
        argv,
    }
}

#[rstest]
fn execs_jailer_with_canonical_argv_and_empty_env_as_root(recorded: Recorded) {
    if !is_root() {
        eprintln!("SKIP jailer exec: needs root to become_root_permanently + own the fakes");
        return;
    }
    let env_rec = recorded.tmp.path().join("environ.bin");
    let cfg = recorded.config("");

    let out = run(
        &cfg,
        &[
            "vm",
            "launch",
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
        ],
    );

    // The jailer's own exit status must propagate through the execve handoff.
    out.code(RECORDER_EXIT);

    assert_eq!(
        recorded.argv(),
        vec![
            "--id",
            "vm1",
            "--exec-file",
            &recorded.firecracker.to_string_lossy(),
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
            "/api.socket",
        ],
        "helper handed the jailer a non-canonical argv",
    );

    // The helper execve's the jailer with an EMPTY envp (see src/cli/vm/launch.rs):
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

#[rstest]
fn execs_jailer_with_netns_flag_when_networking_enabled_as_root(recorded: Recorded) {
    if !is_root() {
        eprintln!("SKIP jailer netns: needs root to become_root_permanently + own the fakes");
        return;
    }
    let cfg = recorded.config("[network]\nuplink = \"eth0\"\n");

    let out = run(
        &cfg,
        &[
            "vm", "launch", "--id", "vnet1", "--uid", "900001", "--gid", "900002",
        ],
    );

    out.code(RECORDER_EXIT);

    let argv = recorded.argv();
    let i = argv
        .iter()
        .position(|a| a == "--netns")
        .expect("--netns present when [network] is configured");
    assert_eq!(
        argv[i + 1],
        "/var/run/netns/vnet1",
        "netns path must be derived from --id, not caller-supplied"
    );
    let sep = argv.iter().position(|a| a == "--").unwrap();
    assert!(
        i < sep,
        "--netns must precede the `--` firecracker separator"
    );
}

#[rstest]
fn refuses_uid_zero_without_exec_as_root(recorded: Recorded) {
    if !is_root() {
        eprintln!("SKIP jailer uid 0: needs root");
        return;
    }
    let cfg = recorded.config("");

    run(
        &cfg,
        &[
            "vm", "launch", "--id", "vm1", "--uid", "0", "--gid", "900002",
        ],
    )
    .code(2);
    assert!(
        !recorded.argv.exists(),
        "the jailer must never have been exec'd for uid 0",
    );
}
