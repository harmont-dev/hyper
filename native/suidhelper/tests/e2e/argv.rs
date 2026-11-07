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

    fn backing(&self, name: &str) -> String {
        let path = self.base.join(name);
        fs::File::create(&path)
            .unwrap()
            .set_len(1024 * 1024)
            .unwrap();
        path.display().to_string()
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
#[case::linear_over_a_file(
    &["linear", "hyper-img", "--readonly", "--sectors", "100", "--origin", "{file:base.img}"],
    true,
    "0 100 linear {origin} 0"
)]
#[case::readonly_snapshot_over_a_dm_device(
    &["snapshot", "hyper-vm1", "--readonly", "--sectors", "100", "--origin", "/dev/mapper/hyper-img",
      "--cow", "{file:cow.img}", "--chunk-sectors", "8"],
    true,
    "0 100 snapshot /dev/mapper/hyper-img {cow} P 8"
)]
#[case::writable_snapshot_over_a_file(
    &["snapshot", "hyper-fork", "--sectors", "100", "--origin", "{file:base.img}",
      "--cow", "{file:cow.img}", "--chunk-sectors", "16"],
    false,
    "0 100 snapshot {origin} {cow} P 16"
)]
#[case::thin_pool(
    &["thin-pool", "hyper-pool", "--sectors", "100", "--metadata", "{file:meta.img}",
      "--data", "{file:data.img}", "--block-sectors", "128", "--low-water", "0"],
    false,
    "0 100 thin-pool {metadata} {data} 128 0"
)]
#[case::thin_with_an_external_origin(
    &["thin", "hyper-vm1", "--sectors", "100", "--pool", "hyper-pool", "--thin-id", "7",
      "--origin", "/dev/mapper/hyper-img"],
    false,
    "0 100 thin /dev/mapper/hyper-pool 7 /dev/mapper/hyper-img"
)]
#[case::thin_without_an_origin(
    &["thin", "hyper-vm1", "--sectors", "100", "--pool", "hyper-pool", "--thin-id", "7"],
    false,
    "0 100 thin /dev/mapper/hyper-pool 7"
)]
fn dm_create_renders_the_table_over_the_attached_loops_as_root(
    fake: FakeDmsetup,
    #[case] args: &[&str],
    #[case] readonly: bool,
    #[case] table: &str,
) {
    if !is_root() {
        eprintln!("SKIP dm create: needs root to attach loops + own the fake bin");
        return;
    }
    let cfg = fake.printing("");
    let args: Vec<String> = args
        .iter()
        .map(
            |arg| match arg.strip_prefix("{file:").and_then(|a| a.strip_suffix('}')) {
                Some(name) => fake.backing(name),
                None => arg.to_string(),
            },
        )
        .collect();
    let argv: Vec<&str> = ["dm"]
        .into_iter()
        .chain(args.iter().map(String::as_str))
        .collect();

    let json = stdout_json(&run(&cfg, &argv).success());

    let loops = json["loops"].as_object().unwrap();
    let table = loops.iter().fold(table.to_string(), |table, (role, path)| {
        let path = path.as_str().unwrap();
        assert!(path.starts_with("/dev/loop"), "{role} loop: {path}");
        table.replace(&format!("{{{role}}}"), path)
    });
    assert!(
        !table.contains('{'),
        "a backing file was not attached: {table}"
    );
    let name = args[1].clone();
    let expected: Vec<String> = ["create".to_string(), name.clone()]
        .into_iter()
        .chain(readonly.then(|| "--readonly".to_string()))
        .chain(["--table".to_string(), table])
        .collect();
    assert_eq!(recorded_argv(&fake.rec), expected);
    assert_eq!(json["device"], format!("/dev/mapper/{name}"));
}

#[rstest]
#[case::foreign_name(&["linear", "sda1", "--sectors", "8", "--origin", "/dev/mapper/hyper-img"])]
#[case::foreign_origin_device(&["linear", "hyper-img", "--sectors", "8", "--origin", "/dev/mapper/root"])]
#[case::foreign_pool(&["thin", "hyper-vm1", "--sectors", "8", "--pool", "vg0-pool", "--thin-id", "1"])]
#[case::foreign_thin_origin(
    &["thin", "hyper-vm1", "--sectors", "8", "--pool", "hyper-pool", "--thin-id", "1",
      "--origin", "/dev/mapper/root"]
)]
#[case::backing_file_outside_the_work_dir(&["linear", "hyper-img", "--sectors", "8", "--origin", "/etc/passwd"])]
#[case::missing_backing_file(&["linear", "hyper-img", "--sectors", "8", "--origin", "{base}/absent.img"])]
#[case::traversing_backing_file(&["linear", "hyper-img", "--sectors", "8", "--origin", "{base}/../etc/passwd"])]
#[case::relative_cow(
    &["snapshot", "hyper-vm1", "--sectors", "8", "--origin", "/dev/mapper/hyper-img",
      "--cow", "cow.img", "--chunk-sectors", "8"]
)]
#[case::thin_id_past_24_bits(&["thin", "hyper-vm1", "--sectors", "8", "--pool", "hyper-pool", "--thin-id", "16777216"])]
#[case::missing_sectors(&["linear", "hyper-img", "--origin", "/dev/mapper/hyper-img"])]
#[case::unknown_message(&["message", "hyper-pool", "--message", "set_transaction_id 0 1"])]
#[case::foreign_remove(&["remove", "root"])]
fn dm_refuses_before_running_dmsetup_as_root(fake: FakeDmsetup, #[case] args: &[&str]) {
    if !is_root() {
        eprintln!("SKIP dm refusal: needs root to own the config");
        return;
    }
    let cfg = fake.printing("");
    let base = fake.base.display().to_string();
    let argv: Vec<String> = ["dm"]
        .iter()
        .chain(args)
        .map(|arg| arg.replace("{base}", &base))
        .collect();
    let argv: Vec<&str> = argv.iter().map(String::as_str).collect();

    run(&cfg, &argv).failure();
    assert!(!fake.ran(), "dmsetup ran for a refused operand: {argv:?}");
}

#[rstest]
#[case::remove_once("", &["remove", "hyper-vm1"], &["remove", "hyper-vm1"])]
#[case::remove_retry("", &["remove", "--retry", "hyper-vm1"], &["remove", "--retry", "hyper-vm1"])]
#[case::suspend("", &["suspend", "hyper-vm1"], &["suspend", "hyper-vm1"])]
#[case::resume("", &["resume", "hyper-vm1"], &["resume", "hyper-vm1"])]
// the helper passes the whole message as a single argv element (dmsetup re-joins remaining args)
#[case::message_create_thin(
    "0 100 thin-pool 7:0 7:1 128 0 0",
    &["message", "hyper-pool", "--message", "create_thin 7"],
    &["message", "hyper-pool", "0", "create_thin 7"]
)]
#[case::message_create_snap(
    "0 100 thin-pool 7:0 7:1 128 0 0",
    &["message", "hyper-pool", "--message", "create_snap 8 7"],
    &["message", "hyper-pool", "0", "create_snap 8 7"]
)]
#[case::message_delete(
    "0 100 thin-pool 7:0 7:1 128 0 0",
    &["message", "hyper-pool", "--message", "delete 8"],
    &["message", "hyper-pool", "0", "delete 8"]
)]
fn dm_device_op_argv_as_root(
    fake: FakeDmsetup,
    #[case] stdout_line: &str,
    #[case] args: &[&str],
    #[case] expected: &[&str],
) {
    if !is_root() {
        eprintln!("SKIP dm argv: needs root");
        return;
    }
    let cfg = fake.printing(stdout_line);

    run(&cfg, &[&["dm"], args].concat()).success();
    assert_eq!(recorded_argv(&fake.rec), expected);
}

#[rstest]
fn dm_message_refuses_a_device_that_is_not_a_thin_pool_as_root(fake: FakeDmsetup) {
    if !is_root() {
        eprintln!("SKIP dm message pool check: needs root");
        return;
    }
    let cfg = fake.printing("0 100 linear 7:0 0");

    run(
        &cfg,
        &["dm", "message", "hyper-vm1", "--message", "delete 1"],
    )
    .failure()
    .stderr(contains("not a thin-pool"));
    assert_eq!(recorded_argv(&fake.rec), ["table", "hyper-vm1"]);
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

    run(&cfg, &["dm", "remove", "hyper-vm1"])
        .failure()
        .stderr(contains("basename must be"));
}
