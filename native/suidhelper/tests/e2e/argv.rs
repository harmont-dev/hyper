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
use support::{is_root, run, stdout_json};

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

#[rstest]
fn dmsetup_create_snapshot_reconstructs_canonical_table_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_create: needs root to acquire + own the fake bin");
        return;
    }
    let tmp = TempDir::new().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let rec = base.join("argv.json");
    let bin = install_fake(&base, "dmsetup", &rec, "");
    let cfg = write_root_config_in(&base, &base, &[("dmsetup", &bin)]);
    let cow = base.join("cow.img");
    fs::File::create(&cow)
        .unwrap()
        .set_len(1024 * 1024)
        .unwrap();

    // Deliberately weird inner spacing; the helper must re-render canonically.
    let table = format!(
        "0   100  snapshot  /dev/mapper/hyper-img   {} P 8",
        cow.display()
    );
    let out = run(
        &cfg,
        &[
            "dmsetup",
            "create",
            "hyper-vm1",
            "--readonly",
            "--table",
            &table,
        ],
    )
    .success();

    let json = stdout_json(&out);
    let cow_loop = json["loops"]["cow"]
        .as_str()
        .expect("helper must report the loop it attached for the cow file");
    assert!(cow_loop.starts_with("/dev/loop"), "cow loop: {cow_loop}");

    let argv = recorded_argv(&rec);
    assert_eq!(
        argv,
        vec![
            "create".to_string(),
            "hyper-vm1".to_string(),
            "--readonly".to_string(),
            "--table".to_string(),
            format!("0 100 snapshot /dev/mapper/hyper-img {cow_loop} P 8"),
        ],
        "helper did not substitute the attached loop into the canonical table",
    );
}

struct FakeDmsetup {
    tmp: TempDir,
    rec: PathBuf,
}

impl FakeDmsetup {
    fn printing(&self, stdout_line: &str) -> PathBuf {
        let bin = install_fake(self.tmp.path(), "dmsetup", &self.rec, stdout_line);
        write_root_config(self.tmp.path(), &[("dmsetup", &bin)])
    }
}

#[fixture]
fn fake() -> FakeDmsetup {
    let tmp = TempDir::new().unwrap();
    let rec = tmp.path().join("argv.json");
    FakeDmsetup { tmp, rec }
}

#[rstest]
#[case::remove_retry("", &["remove", "--retry", "hyper-vm1"], &["remove", "--retry", "hyper-vm1"])]
// the helper passes the whole message as a single argv element (dmsetup re-joins remaining args)
#[case::message_create_thin(
    "0 100 thin-pool 7:0 7:1 128 0 0",
    &["message", "hyper-pool", "--message", "create_thin 7"],
    &["message", "hyper-pool", "0", "create_thin 7"]
)]
fn dmsetup_argv_as_root(
    fake: FakeDmsetup,
    #[case] stdout_line: &str,
    #[case] args: &[&str],
    #[case] expected: &[&str],
) {
    if !is_root() {
        eprintln!("SKIP dmsetup_argv: needs root");
        return;
    }
    let cfg = fake.printing(stdout_line);

    run(&cfg, &[&["dmsetup"], args].concat()).success();
    assert_eq!(recorded_argv(&fake.rec), expected);
}

#[rstest]
#[case::targets("snapshot         v1.16.0", "targets", "targets", "snapshot v1.16.0\n")]
#[case::ls(
    "hyper-thinpool\\nhyper-rw-abc",
    "ls",
    "listed",
    "hyper-thinpool\nhyper-rw-abc\n"
)]
fn dmsetup_listing_argv_and_parse_as_root(
    fake: FakeDmsetup,
    #[case] stdout_line: &str,
    #[case] op: &str,
    #[case] result: &str,
    #[case] output: &str,
) {
    if !is_root() {
        eprintln!("SKIP dmsetup_{op}: needs root");
        return;
    }
    let cfg = fake.printing(stdout_line);

    let out = run(&cfg, &["dmsetup", op]).success();
    assert_eq!(recorded_argv(&fake.rec), vec![op]);
    let json = stdout_json(&out);
    assert_eq!(json["result"], result);
    assert_eq!(json["output"], output);
}

#[rstest]
fn dmsetup_rejects_configured_bin_with_wrong_basename_as_root() {
    if !is_root() {
        eprintln!("SKIP dmsetup_rejects_bin: needs root to own the config file");
        return;
    }
    let tmp = TempDir::new().unwrap();
    // A real, root-owned system file, but the wrong basename for `dmsetup`.
    let cfg = write_root_config(tmp.path(), &[("dmsetup", Path::new("/usr/bin/env"))]);

    run(&cfg, &["dmsetup", "targets"])
        .failure()
        .stderr(contains("basename must be"));
}

struct LoopDevice(String);

impl LoopDevice {
    fn attach(backing: &Path) -> Self {
        let out = std::process::Command::new("losetup")
            .args(["--find", "--show"])
            .arg(backing)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        Self(String::from_utf8(out.stdout).unwrap().trim().to_string())
    }
}

impl Drop for LoopDevice {
    fn drop(&mut self) {
        let _ = std::process::Command::new("losetup")
            .args(["--detach", &self.0])
            .status();
    }
}

struct MapperDevice {
    name: String,
    _loop_dev: LoopDevice,
}

impl MapperDevice {
    fn linear(loop_dev: LoopDevice, sectors: u64) -> Self {
        let name = format!("hyper-e2e-getsz-{}", std::process::id());
        let table = format!("0 {sectors} linear {} 0", loop_dev.0);
        let out = std::process::Command::new("dmsetup")
            .args(["create", &name, "--table", &table])
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        Self {
            name,
            _loop_dev: loop_dev,
        }
    }

    fn path(&self) -> String {
        format!("/dev/mapper/{}", self.name)
    }
}

impl Drop for MapperDevice {
    fn drop(&mut self) {
        let _ = std::process::Command::new("dmsetup")
            .args(["remove", "--retry", &self.name])
            .status();
    }
}

#[rstest]
fn blockdev_getsz_reports_a_dm_devices_size_as_root() {
    if !is_root() {
        eprintln!("SKIP blockdev: needs root");
        return;
    }
    let tmp = TempDir::new().unwrap();
    let backing = tmp.path().join("backing");
    fs::File::create(&backing)
        .unwrap()
        .set_len(3 * 1024 * 1024 + 512)
        .unwrap();
    let dev = MapperDevice::linear(LoopDevice::attach(&backing), 6145);
    let cfg = write_root_config(tmp.path(), &[]);

    let out = run(&cfg, &["blockdev", "--getsz", &dev.path()]).success();
    let json = stdout_json(&out);
    assert_eq!(json["sectors"], 6145);
}
