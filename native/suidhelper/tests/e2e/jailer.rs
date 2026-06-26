//! L4 for the jailer handoff: prove the exact argv (and an EMPTY environment) the
//! helper hands to the jailer via `execve`, and that the jailer's exit status
//! propagates. We point the config's `jailer` at a root-owned recorder that
//! writes its argv and its `/proc/self/environ` to files, then exits with a known
//! code. Root-only: `become_root_permanently` requires we are already root.
#![cfg(feature = "insecure_test_seams")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const HELPER: &str = env!("CARGO_BIN_EXE_hyper-suidhelper");
const RECORDER_EXIT: i32 = 7;

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

fn cat_bin() -> &'static str {
    ["/bin/cat", "/usr/bin/cat"]
        .into_iter()
        .find(|p| Path::new(p).exists())
        .expect("a `cat` binary for the recorder")
}

/// Install a root-owned recorder named `jailer` that writes its argv (minus
/// argv[0]) as a JSON array to `argv_rec` and copies its `/proc/self/environ` to
/// `env_rec`, then exits `RECORDER_EXIT`. Paths are baked into the script text
/// because the recorder runs with an empty environment and absolute `cat` so it
/// needs no `PATH`. Returns the recorder's absolute path.
fn install_recorder(dir: &Path, argv_rec: &Path, env_rec: &Path) -> PathBuf {
    let path = dir.join("jailer");
    let script = format!(
        "#!/bin/sh\n\
         (\n  printf '['\n  sep=''\n  for a in \"$@\"; do printf '%s\"%s\"' \"$sep\" \"$a\"; sep=','; done\n  printf ']'\n) > '{argv}'\n\
         {cat} /proc/self/environ > '{env}'\n\
         exit {code}\n",
        argv = argv_rec.display(),
        cat = cat_bin(),
        env = env_rec.display(),
        code = RECORDER_EXIT,
    );
    fs::write(&path, script).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// A root-owned plain file with basename `firecracker` — the `--exec-file`. It is
/// never executed by us (the jailer would), only validated as a `SafeBin`.
fn install_firecracker(dir: &Path) -> PathBuf {
    let path = dir.join("firecracker");
    fs::write(&path, b"#!/bin/true\n").unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
    path
}

fn write_root_config(dir: &Path, jailer: &Path, firecracker: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    let body = format!(
        "work_dir = \"/srv/hyper\"\njailer = \"{}\"\nfirecracker = \"{}\"\n",
        jailer.display(),
        firecracker.display(),
    );
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

fn run(config: &Path, args: &[&str]) -> std::process::Output {
    Command::new(HELPER)
        .args(args)
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config)
        .output()
        .expect("spawn helper")
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
    let jailer = install_recorder(tmp.path(), &argv_rec, &env_rec);
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
            "--cgroup",
            "memory.max=1048576",
            "--cgroup",
            "cpu.max=100000 100000",
            "--api-sock",
            "/api.sock",
        ],
    );

    // The jailer's own exit status must propagate through the execve handoff.
    assert_eq!(
        out.status.code(),
        Some(RECORDER_EXIT),
        "exit status did not propagate; stderr: {}",
        String::from_utf8_lossy(&out.stderr),
    );

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
fn refuses_uid_zero_without_exec_as_root() {
    if !is_root() {
        eprintln!("SKIP jailer uid 0: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let argv_rec = tmp.path().join("argv.json");
    let env_rec = tmp.path().join("environ.bin");
    let jailer = install_recorder(tmp.path(), &argv_rec, &env_rec);
    let firecracker = install_firecracker(tmp.path());
    let cfg = write_root_config(tmp.path(), &jailer, &firecracker);

    let out = run(
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
    );

    assert_ne!(out.status.code(), Some(0), "uid 0 must be refused");
    assert_eq!(out.status.code(), Some(2), "validation failure exits 2");
    assert!(
        !argv_rec.exists(),
        "the jailer must never have been exec'd for uid 0",
    );
}
