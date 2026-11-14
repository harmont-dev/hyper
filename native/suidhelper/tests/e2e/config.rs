//! L5: the binary's startup config contract, observed end to end (exit code +
//! stderr + stdout JSON). Uses the config-path seam to point at a per-test
//! tempfile instead of /etc/hyper, so tests never touch the real host.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use hyper_suidhelper::config::{BinError, Config};
use hyperrs_process::binary;
use predicates::boolean::PredicateBooleanExt;
use predicates::str::contains;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use serde_json::json;
use std::assert_matches;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command as Process;

mod support;
use support::{is_root, run, stdout_json, ScratchNs, BIN, NET_TABLE};

#[fixture]
fn tmp() -> TempDir {
    TempDir::new().unwrap()
}

/// Write a config file owned root:root, 0644. Requires the test run as root.
fn write_root_config(dir: &Path, body: &str) -> std::path::PathBuf {
    let p = dir.join("config.toml");
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    // Owned by root because the test process is root (checked by callers).
    p
}

/// A genuinely-absent config file is NOT an error: the helper falls back to the
/// built-in defaults (compiled into this root-owned binary, hence trusted).
#[rstest]
#[case::missing_config_falls_back_to_defaults(None)]
#[case::valid_config(Some("work_dir = \"/srv/hyper\"\n"))]
fn a_trusted_config_loads_and_the_helper_elevates_as_root(
    tmp: TempDir,
    #[case] body: Option<&str>,
) {
    if !is_root() {
        eprintln!("SKIP config loads: needs root");
        return;
    }
    let cfg = match body {
        Some(body) => write_root_config(tmp.path(), body),
        None => tmp.path().join("nope.toml"),
    };
    let ns = ScratchNs::new(if body.is_some() {
        "cfg-valid"
    } else {
        "cfg-missing"
    });
    let out = ns
        .run(&cfg, json!({"op": "vm_teardown", "id": "vconfige2e"}))
        .success();
    assert_eq!(stdout_json(&out)["result"], "tore_down");
}

#[rstest]
fn host_init_reports_the_work_dir_the_helper_trusts_as_root(tmp: TempDir) {
    if !is_root() {
        eprintln!("SKIP host_init: needs root");
        return;
    }
    let cfg = write_root_config(
        tmp.path(),
        &format!("work_dir = \"/srv/hyper\"\n{NET_TABLE}"),
    );
    let ns = ScratchNs::new("host-init");

    let out = ns.run(&cfg, json!({"op": "host_init"})).success();

    assert_eq!(
        stdout_json(&out),
        json!({
            "result": "host_ready",
            "hyper_base": "/srv/hyper",
            "net": {
                "uplink": "lo",
                "transit_prefix": "10.200.0.0/16",
                "vm_prefix": "2001:db8:0:0:1::/80",
            },
        })
    );
    let read = |key: &str| {
        fs::read_to_string(format!("/proc/sys/{key}"))
            .unwrap()
            .trim()
            .to_owned()
    };
    let sysctls = ns
        .get()
        .scoped(|| {
            [
                read("net/ipv4/ip_forward"),
                read("net/ipv6/conf/all/forwarding"),
                read("net/ipv6/conf/lo/proxy_ndp"),
            ]
        })
        .unwrap();
    assert_eq!(sysctls, ["1", "1", "1"]);
}

#[rstest]
fn host_init_without_a_net_table_is_refused_as_root(tmp: TempDir) {
    if !is_root() {
        eprintln!("SKIP host_init without [net]: needs root");
        return;
    }
    let cfg = write_root_config(tmp.path(), "work_dir = \"/srv/hyper\"\n");
    let ns = ScratchNs::new("host-init-unconfigured");

    ns.run(&cfg, json!({"op": "host_init"}))
        .code(2)
        .stderr(contains("[net]"));
}

#[rstest]
fn non_root_owned_config_is_rejected(tmp: TempDir) {
    // A config file owned by a non-root user must be refused. If the test runs
    // as root, chown it away from root to exercise the owner check.
    let p = tmp.path().join("config.toml");
    fs::write(&p, "work_dir = \"/srv/hyper\"\n").unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    if is_root() {
        // Drop ownership to uid/gid 65534 (nobody) so it is no longer root-owned.
        let nobody = nix::unistd::Uid::from_raw(65534);
        let nogrp = nix::unistd::Gid::from_raw(65534);
        nix::unistd::chown(&p, Some(nobody), Some(nogrp)).unwrap();
    }
    run(&p, json!({"op": "vm_teardown", "id": "vconfige2e"}))
        .code(2)
        .stderr(contains("root:root").or(contains("not owned")));
}

#[rstest]
#[case::malformed("this is not = valid = toml ===", "not valid TOML")]
#[case::relative_work_dir("work_dir = \"relative/path\"\n", "path is not absolute")]
// min = 0 is the clearest violation: uid 0 is root, which the jailer must
// never receive because it skips its privilege drop when uid == 0.
#[case::bad_uid_gid_range(
    "work_dir = \"/srv/hyper\"\n[jails]\nuid_gid_range = [0, 100]\n",
    "uid_gid_range"
)]
fn invalid_config_exits_2_as_root(tmp: TempDir, #[case] body: &str, #[case] stderr: &str) {
    if !is_root() {
        eprintln!("SKIP invalid_config: needs root to own the config file");
        return;
    }
    let p = write_root_config(tmp.path(), body);
    run(&p, json!({"op": "vm_teardown", "id": "vconfige2e"}))
        .code(2)
        .stderr(contains(stderr));
}

// Config::default() has firecracker == None; the accessor must signal this
// distinctly so callers can report a missing-configuration error rather than
// a binary validation error.
#[rstest]
#[case::firecracker("firecracker", |c: &Config| c.firecracker().map(drop))]
#[case::jailer("jailer", |c: &Config| c.jailer().map(drop))]
fn tool_unconfigured_when_absent(
    #[case] tool: &str,
    #[case] accessor: fn(&Config) -> Result<(), BinError>,
) {
    let err = accessor(&Config::default()).expect_err("absent tool must return Unconfigured");
    assert_matches!(err, BinError::Unconfigured(name) if name == tool);
}

#[rstest]
fn jailer_basename_mismatch_rejected() {
    // The basename check in RootSafeBin::open precedes the stat, so we do not
    // need a real file — any absolute path with the wrong leaf name is enough.
    let body = "work_dir = \"/srv/hyper\"\n[tools]\njailer = \"/usr/local/bin/not-jailer\"\n";
    let config: Config = toml::from_str(body).unwrap();
    let err = config
        .jailer()
        .expect_err("wrong-basename jailer path must be rejected");
    assert_matches!(err, BinError::Bin(binary::RootSafeBinError::Name { .. }));
}

#[rstest]
fn firecracker_and_jailer_return_ok_when_root_owned_as_root(tmp: TempDir) {
    if !is_root() {
        eprintln!("SKIP firecracker_jailer_configured: needs root to create root-owned binaries");
        return;
    }
    let fc = tmp.path().join("firecracker");
    let jr = tmp.path().join("jailer");
    // 0o755: root-owned, not group/other-writable — satisfies RootSafeBin's checks.
    for p in [&fc, &jr] {
        fs::write(p, b"#!/bin/sh\n").unwrap();
        fs::set_permissions(p, fs::Permissions::from_mode(0o755)).unwrap();
    }
    let body = format!(
        "work_dir = \"/srv/hyper\"\n[tools]\nfirecracker = \"{}\"\njailer = \"{}\"\n",
        fc.display(),
        jr.display(),
    );
    let config: Config = toml::from_str(&body).unwrap();
    assert!(
        config.firecracker().is_ok(),
        "root-owned firecracker with correct basename must be accepted"
    );
    assert!(
        config.jailer().is_ok(),
        "root-owned jailer with correct basename must be accepted"
    );
}

#[rstest]
#[case::its_group_runs_privileged_ops(None, json!({"op": "vm_teardown", "id": "vconfige2e"}), "")]
#[case::another_group_is_refused(Some("daemon"), json!({"op": "vm_teardown", "id": "vconfige2e"}), "is not in the helper's group")]
#[case::a_root_group_refuses_everyone_but_root(Some("root"), json!({"op": "vm_teardown", "id": "vconfige2e"}), "installed with group root")]
#[case::version_answers_anyone(Some("root"), json!({"op": "version"}), "")]
fn only_root_and_the_helpers_group_may_run_privileged_ops_as_root(
    tmp: TempDir,
    #[case] installed_group: Option<&str>,
    #[case] request: serde_json::Value,
    #[case] refusal: &str,
) {
    if !is_root() {
        eprintln!("SKIP caller authorization: needs root to install the helper and switch uid");
        return;
    }
    let nobody = nix::unistd::User::from_name("nobody").unwrap().unwrap();
    let group = installed_group.map_or(nobody.gid, |name| {
        nix::unistd::Group::from_name(name).unwrap().unwrap().gid
    });
    fs::set_permissions(tmp.path(), fs::Permissions::from_mode(0o755)).unwrap();
    let bin = tmp.path().join("hyper-suidhelper");
    fs::copy(BIN, &bin).unwrap();
    nix::unistd::chown(&bin, None, Some(group)).unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();

    let mut cmd = Process::new(&bin);
    cmd.arg(request.to_string())
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env(
            "HYPER_SETUIDHELPER_CONFIG_PATH",
            tmp.path().join("absent.toml"),
        )
        .uid(nobody.uid.as_raw())
        .gid(nobody.gid.as_raw());
    let output = cmd.output().unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);

    if refusal.is_empty() {
        assert!(!stderr.contains("may run it"), "{stderr}");
    } else {
        assert_eq!(output.status.code(), Some(2), "{stderr}");
        assert!(stderr.contains(refusal), "{stderr}");
    }
}
