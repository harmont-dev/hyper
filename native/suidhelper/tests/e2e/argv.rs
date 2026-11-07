//! L4: prove the exact argv (and empty env) the helper hands to the child tool —
//! the one thing the design deliberately hides from the caller. We point the
//! tool's config path at a root-owned fake that writes its argv+env to a file as
//! JSON, then assert on the reconstructed command line.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use predicates::str::contains;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

mod support;
use serde_json::{json, Value};
use support::{is_root, run, run_args};

/// Install a root-owned fake tool named `basename` that records its argv (minus
/// argv[0]) into `record` as a JSON array, then exits 0 with valid stdout for
/// the helper's parser. Returns the fake's absolute path.
fn install_fake(dir: &Path, basename: &str, record: &Path, stdout_line: &str) -> PathBuf {
    let path = dir.join(basename);
    // A tiny shell fake. `printf '%s\n'` of a JSON array of args. stdout_line is
    // what the helper's `parse` expects (e.g. a loop device path or sectors).
    let script = format!(
        "#!/bin/sh\nprintf '%s' \"$(\n  printf '['\n  sep=''\n  for a in \"$@\"; do printf '%s\"%s\"' \"$sep\" \"$a\"; sep=','; done\n  printf ']'\n)\" > '{record}'\nprintf '{stdout_line}\\n'\n",
        record = record.display(),
    );
    fs::write(&path, script).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path // root-owned because this test runs as root
}

/// Write a root-owned config that points the named tools at the given (fake)
/// binaries, so the helper resolves each tool's path from config rather than a
/// caller argument.
fn write_root_config(dir: &Path, bins: &[(&str, &Path)]) -> PathBuf {
    write_root_config_in(dir, Path::new("/srv/hyper"), bins)
}

fn write_root_config_in(dir: &Path, work_dir: &Path, bins: &[(&str, &Path)]) -> PathBuf {
    let p = dir.join("config.toml");
    // Every key here is a tool name, so they live under the `[tools]` table.
    let mut body = format!("work_dir = \"{}\"\n[tools]\n", work_dir.display());
    for (key, path) in bins {
        body.push_str(&format!("{key} = \"{}\"\n", path.display()));
    }
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

fn recorded_argv(record: &Path) -> Vec<String> {
    let body = fs::read_to_string(record).expect("fake recorded argv");
    serde_json::from_str(&body).expect("argv json")
}

struct FakeDmsetup {
    _tmp: TempDir,
    base: PathBuf,
    rec: PathBuf,
}

impl FakeDmsetup {
    fn printing(&self, stdout_line: &str) -> PathBuf {
        let bin = install_fake(&self.base, "dmsetup", &self.rec, stdout_line);
        write_root_config_in(&self.base, &self.base, &[("dmsetup", &bin)])
    }

    fn ran(&self) -> bool {
        self.rec.exists()
    }
}

#[fixture]
fn fake() -> FakeDmsetup {
    let tmp = TempDir::new().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let rec = base.join("argv.json");
    FakeDmsetup {
        _tmp: tmp,
        base,
        rec,
    }
}

#[rstest]
#[case::remove_once(json!({"op": "dm_remove", "name": "hyper-vm1", "retry": false}),
    &["remove", "hyper-vm1"])]
#[case::remove_retry(json!({"op": "dm_remove", "name": "hyper-vm1", "retry": true}),
    &["remove", "--retry", "hyper-vm1"])]
fn dm_remove_argv_as_root(fake: FakeDmsetup, #[case] request: Value, #[case] expected: &[&str]) {
    if !is_root() {
        eprintln!("SKIP dm argv: needs root");
        return;
    }
    let cfg = fake.printing("");

    run(&cfg, request).success();
    assert_eq!(recorded_argv(&fake.rec), expected);
}

#[rstest]
fn dm_rejects_configured_bin_with_wrong_basename_as_root() {
    if !is_root() {
        eprintln!("SKIP dm_rejects_bin: needs root to own the config file");
        return;
    }
    let tmp = TempDir::new().unwrap();
    // A real, root-owned system file, but the wrong basename for `dmsetup`.
    let cfg = write_root_config(tmp.path(), &[("dmsetup", Path::new("/usr/bin/env"))]);

    run(
        &cfg,
        json!({"op": "dm_remove", "name": "hyper-vm1", "retry": false}),
    )
    .failure()
    .stderr(contains("basename must be"));
}

#[rstest]
#[case::no_request(&[])]
#[case::two_requests(&[r#"{"op":"version"}"#, r#"{"op":"version"}"#])]
#[case::legacy_subcommand(&["dmsetup", "ls"])]
#[case::not_json(&["vm teardown --id v1"])]
#[case::unknown_field(&[r#"{"op":"dm_remove","name":"hyper-vm1","retry":false,"table":"0 8 linear /dev/sda 0"}"#])]
fn malformed_requests_exit_2_without_running_anything_as_root(
    fake: FakeDmsetup,
    #[case] args: &[&str],
) {
    if !is_root() {
        eprintln!("SKIP malformed request: needs root to own the config");
        return;
    }
    let cfg = fake.printing("");

    run_args(&cfg, args).code(2);
    assert!(!fake.ran(), "dmsetup ran for {args:?}");
}
