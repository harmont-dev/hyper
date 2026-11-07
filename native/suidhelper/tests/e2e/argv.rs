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
use support::{is_root, run, run_args, stdout_json, MapperDevice};

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

fn substitute(value: &Value, f: &impl Fn(&str) -> Option<String>) -> Value {
    match value {
        Value::String(s) => f(s).map_or_else(|| value.clone(), Value::String),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), substitute(v, f)))
                .collect(),
        ),
        _ => value.clone(),
    }
}

#[rstest]
#[case::linear_over_a_file(
    json!({"op": "dm_linear", "name": "hyper-img", "readonly": true, "origin": "{file:base.img}"}),
    "0 2048 linear {origin} 0"
)]
#[case::linear_over_a_dm_device(
    json!({"op": "dm_linear", "name": "hyper-img", "readonly": true, "origin": "{dm}"}),
    "0 2048 linear {dm} 0"
)]
#[case::readonly_snapshot_over_a_dm_device(
    json!({"op": "dm_snapshot", "name": "hyper-vm1", "readonly": true, "origin": "{dm}",
           "cow": "{file:cow.img}", "chunk_sectors": 8}),
    "0 2048 snapshot {dm} {cow} P 8"
)]
#[case::writable_snapshot_over_a_file(
    json!({"op": "dm_snapshot", "name": "hyper-fork", "readonly": false, "origin": "{file:base.img}",
           "cow": "{file:cow.img}", "chunk_sectors": 16}),
    "0 2048 snapshot {origin} {cow} P 16"
)]
#[case::thin_pool_sized_by_its_data_file(
    json!({"op": "dm_thin_pool", "name": "hyper-pool", "metadata": "{file:meta.img}",
           "data": "{file:data.img}", "block_sectors": 128, "low_water": 0}),
    "0 2048 thin-pool {metadata} {data} 128 0"
)]
#[case::thin_sized_by_its_external_origin(
    json!({"op": "dm_thin", "name": "hyper-vm1", "pool": "hyper-pool", "thin_id": 7, "origin": "{dm}"}),
    "0 2048 thin /dev/mapper/hyper-pool 7 {dm}"
)]
fn dm_create_sizes_and_renders_the_table_over_the_attached_loops_as_root(
    fake: FakeDmsetup,
    #[case] request: Value,
    #[case] table: &str,
) {
    if !is_root() {
        eprintln!("SKIP dm create: needs root to attach loops + own the fake bin");
        return;
    }
    let cfg = fake.printing("");
    let origin_file = fake.base.join("origin-dev.img");
    fs::write(&origin_file, vec![0u8; 1024 * 1024]).unwrap();
    let Some(origin) = MapperDevice::linear(
        &format!("hyper-e2e-origin-{}", std::process::id()),
        &origin_file,
    ) else {
        eprintln!("SKIP dm create: losetup/dmsetup unavailable");
        return;
    };
    let dm = origin.path();
    let request = substitute(&request, &|s| match s.strip_prefix("{file:") {
        Some(name) => Some(fake.backing(name.strip_suffix('}')?)),
        None => (s == "{dm}").then(|| dm.clone()),
    });

    let json = stdout_json(&run(&cfg, request.clone()).success());

    let loops = json["loops"].as_object().unwrap();
    let table = loops
        .iter()
        .fold(table.replace("{dm}", &dm), |table, (role, path)| {
            let path = path.as_str().unwrap();
            assert!(path.starts_with("/dev/loop"), "{role} loop: {path}");
            table.replace(&format!("{{{role}}}"), path)
        });
    assert!(
        !table.contains('{'),
        "a backing file was not attached: {table}"
    );
    let name = request["name"].as_str().unwrap();
    let readonly = request["readonly"] == json!(true);
    let expected: Vec<String> = ["create".to_string(), name.to_string()]
        .into_iter()
        .chain(readonly.then(|| "--readonly".to_string()))
        .chain(["--table".to_string(), table])
        .collect();
    assert_eq!(recorded_argv(&fake.rec), expected);
    assert_eq!(json["device"], format!("/dev/mapper/{name}"));
}

#[rstest]
#[case::foreign_origin_device(json!({"op": "dm_linear", "name": "hyper-img", "readonly": true, "origin": "/dev/mapper/root"}))]
#[case::foreign_thin_origin(json!({"op": "dm_thin", "name": "hyper-vm1",
    "pool": "hyper-pool", "thin_id": 1, "origin": "/dev/mapper/root"}))]
#[case::backing_file_outside_the_work_dir(json!({"op": "dm_linear", "name": "hyper-img",
    "readonly": true, "origin": "/etc/passwd"}))]
#[case::missing_backing_file(json!({"op": "dm_linear", "name": "hyper-img", "readonly": true, "origin": "{base}/absent.img"}))]
#[case::traversing_backing_file(json!({"op": "dm_linear", "name": "hyper-img", "readonly": true, "origin": "{base}/../etc/passwd"}))]
#[case::symlinked_backing_file(json!({"op": "dm_linear", "name": "hyper-img", "readonly": true, "origin": "{base}/link.img"}))]
#[case::directory_as_backing_file(json!({"op": "dm_snapshot", "name": "hyper-vm1", "readonly": true, "origin": "/dev/mapper/hyper-img", "cow": "{base}", "chunk_sectors": 8}))]
#[case::absent_origin_device(json!({"op": "dm_linear", "name": "hyper-img", "readonly": true,
    "origin": "/dev/mapper/hyper-e2e-absent"}))]
#[case::foreign_name(json!({"op": "dm_linear", "name": "sda1", "readonly": true,
    "origin": "/dev/mapper/hyper-img"}))]
#[case::foreign_pool(json!({"op": "dm_thin", "name": "hyper-vm1",
    "pool": "vg0-pool", "thin_id": 1, "origin": "/dev/mapper/hyper-img"}))]
#[case::unknown_message(json!({"op": "dm_message", "name": "hyper-pool",
    "message": "set_transaction_id 0 1"}))]
#[case::foreign_remove(json!({"op": "dm_remove", "name": "root", "retry": false}))]
fn dm_refuses_before_running_dmsetup_as_root(fake: FakeDmsetup, #[case] request: Value) {
    if !is_root() {
        eprintln!("SKIP dm refusal: needs root to own the config");
        return;
    }
    let cfg = fake.printing("");
    std::os::unix::fs::symlink("/etc/passwd", fake.base.join("link.img")).unwrap();
    let base = fake.base.display().to_string();
    let request = substitute(&request, &|s| Some(s.replace("{base}", &base)));

    run(&cfg, request.clone()).failure();
    assert!(!fake.ran(), "dmsetup ran for a refused request: {request}");
}

#[rstest]
#[case::remove_once("", json!({"op": "dm_remove", "name": "hyper-vm1", "retry": false}),
    &["remove", "hyper-vm1"])]
#[case::remove_retry("", json!({"op": "dm_remove", "name": "hyper-vm1", "retry": true}),
    &["remove", "--retry", "hyper-vm1"])]
#[case::suspend("", json!({"op": "dm_suspend", "name": "hyper-vm1"}), &["suspend", "hyper-vm1"])]
#[case::resume("", json!({"op": "dm_resume", "name": "hyper-vm1"}), &["resume", "hyper-vm1"])]
// the helper passes the whole message as a single argv element (dmsetup re-joins remaining args)
#[case::message_create_thin(
    "0 100 thin-pool 7:0 7:1 128 0 0",
    json!({"op": "dm_message", "name": "hyper-pool", "message": "create_thin 7"}),
    &["message", "hyper-pool", "0", "create_thin 7"]
)]
#[case::message_create_snap(
    "0 100 thin-pool 7:0 7:1 128 0 0",
    json!({"op": "dm_message", "name": "hyper-pool", "message": "create_snap 8 7"}),
    &["message", "hyper-pool", "0", "create_snap 8 7"]
)]
#[case::message_delete(
    "0 100 thin-pool 7:0 7:1 128 0 0",
    json!({"op": "dm_message", "name": "hyper-pool", "message": "delete 8"}),
    &["message", "hyper-pool", "0", "delete 8"]
)]
fn dm_device_op_argv_as_root(
    fake: FakeDmsetup,
    #[case] stdout_line: &str,
    #[case] request: Value,
    #[case] expected: &[&str],
) {
    if !is_root() {
        eprintln!("SKIP dm argv: needs root");
        return;
    }
    let cfg = fake.printing(stdout_line);

    run(&cfg, request).success();
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
        json!({"op": "dm_message", "name": "hyper-vm1", "message": "delete 1"}),
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
