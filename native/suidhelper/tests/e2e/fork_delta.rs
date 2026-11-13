#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use predicates::str::contains;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

mod support;
use support::{is_root, run, stdout_json, DmDevice, LoopDevice, MapperDevice};

const BLOCK_SECTORS: u64 = 128;
const BLOCK_BYTES: usize = (BLOCK_SECTORS * 512) as usize;
const SCRATCH_ID: u32 = 9;
const REAL_POOL_SCRATCH_ID: u32 = 13;

// One superblock, one device (4 mapped blocks: a 3-block range plus a
// single). Extra attributes mirror real thin_dump output; the parser must
// ignore them. mapped_blocks MUST equal the summed lengths or the parser
// refuses as truncated. Kept on one line: the fake emits it via a single
// printf, and line breaks would add whitespace text nodes to the document.
fn xml(dev_id: u32) -> String {
    format!(
        r#"<superblock uuid="" time="0" transaction="1" data_block_size="128" nr_data_blocks="1000"><device dev_id="{dev_id}" mapped_blocks="4" transaction="0" creation_time="0" snap_time="0"><range_mapping origin_begin="0" data_begin="100" length="3" time="0"/><single_mapping origin_block="9" data_block="200" time="0"/></device></superblock>"#
    )
}

const TABLE: &str = "table hyper-pool";
const POOL_NUMBER: &str = "info -c --noheadings -o major,minor hyper-pool";
const RESERVE: &str = "message hyper-pool 0 reserve_metadata_snap";
const RELEASE: &str = "message hyper-pool 0 release_metadata_snap";

type ThinDumpBody = fn(&Path) -> String;

fn dump_of(dev_id: u32, base: &Path) -> String {
    format!(
        r#"printf '%s\n' "$*" > '{record}'
printf '%s\n' '{xml}'
"#,
        record = base.join("thin_dump.argv").display(),
        xml = xml(dev_id),
    )
}

fn scratch_dump(base: &Path) -> String {
    dump_of(SCRATCH_ID, base)
}

fn another_devices_dump(base: &Path) -> String {
    dump_of(5, base)
}

fn failing_thin_dump(_: &Path) -> String {
    "echo 'metadata snap not reserved' >&2\nexit 1\n".to_string()
}

fn install(dir: &Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn write_config(base: &Path, dmsetup: &Path, thin_dump: &Path) -> PathBuf {
    let config = base.join("config.toml");
    fs::write(
        &config,
        format!(
            "work_dir = \"{}\"\n[tools]\ndmsetup = \"{}\"\nthin_dump = \"{}\"\n",
            base.display(),
            dmsetup.display(),
            thin_dump.display(),
        ),
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o644)).unwrap();
    config
}

struct Pool {
    _dir: TempDir,
    base: PathBuf,
    config: PathBuf,
    origin: MapperDevice,
}

impl Pool {
    fn new(thin_dump_body: ThinDumpBody) -> Option<Self> {
        let dir = TempDir::new().unwrap();
        let base = fs::canonicalize(dir.path()).unwrap();
        let dmsetup = install(
            &base,
            "dmsetup",
            &format!(
                r#"printf '%s\n' "$*" >> '{b}/dmsetup.log'
case "$1" in
  table)
    case "$2" in
      hyper-pool)
        if [ -e '{b}/linear' ]; then printf '0 100 linear 7:0 0\n'; else printf '0 100 thin-pool 7:0 7:1 128 0 0\n'; fi ;;
      hyper-vm1)
        if [ -e '{b}/parent-linear' ]; then printf '0 2048 linear 7:0 0\n'; else printf '0 2048 thin 253:1 7\n'; fi ;;
      *) printf '0 2048 thin 253:1 {SCRATCH_ID}\n' ;;
    esac ;;
  info) printf '253:1\n' ;;
  message)
    if [ "$4" = reserve_metadata_snap ]; then
      if [ -e '{b}/reserved' ]; then echo 'reservation exists' >&2; exit 1; fi
      if [ -e '{b}/stale' ]; then rm '{b}/stale'; echo 'reservation exists' >&2; exit 1; fi
    fi ;;
esac
"#,
                b = base.display(),
            ),
        );
        let thin_dump = install(&base, "thin_dump", &thin_dump_body(&base));
        fs::write(base.join("cow.img"), b"").unwrap();
        fs::write(base.join("origin.img"), vec![0u8; 1 << 20]).unwrap();
        let config = write_config(&base, &dmsetup, &thin_dump);
        let origin = MapperDevice::linear(
            &format!("hyper-e2e-fork-origin-{}", std::process::id()),
            &base.join("origin.img"),
        )?;
        Some(Self {
            _dir: dir,
            base,
            config,
            origin,
        })
    }

    fn mark(&self, marker: &str) {
        fs::write(self.base.join(marker), b"").unwrap();
    }

    fn dmsetup_calls(&self) -> Vec<String> {
        fs::read_to_string(self.base.join("dmsetup.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn thin_dump_ran(&self) -> bool {
        self.thin_dump_argv().is_some()
    }

    fn thin_dump_argv(&self) -> Option<String> {
        fs::read_to_string(self.base.join("thin_dump.argv")).ok()
    }

    fn snapshot_calls(&self) -> Vec<String> {
        [
            TABLE.to_string(),
            "table hyper-vm1".to_string(),
            POOL_NUMBER.to_string(),
            "suspend hyper-vm1".to_string(),
            format!("message hyper-pool 0 create_snap {SCRATCH_ID} 7"),
            "resume hyper-vm1".to_string(),
            format!(
                "create hyper-scratch-{SCRATCH_ID} --table 0 2048 thin /dev/mapper/hyper-pool {SCRATCH_ID} {}",
                self.origin.path()
            ),
        ]
        .into()
    }

    fn fork_delta(&self, overrides: Value) -> assert_cmd::assert::Assert {
        let mut request = json!({
            "op": "thin_fork_delta",
            "pool": "hyper-pool",
            "meta": "/dev/loop3",
            "parent": "hyper-vm1",
            "scratch_id": SCRATCH_ID,
            "origin": self.origin.path(),
            "cow": self.base.join("cow.img"),
            "chunk_sectors": 8,
        });
        request
            .as_object_mut()
            .unwrap()
            .extend(overrides.as_object().unwrap().clone());
        run(&self.config, request)
    }
}

fn scratch(call: &str) -> String {
    call.replace("{scratch}", &format!("hyper-scratch-{SCRATCH_ID}"))
        .replace("{id}", &SCRATCH_ID.to_string())
}

fn dump_calls(reservation: &[&str]) -> Vec<String> {
    [TABLE, "table {scratch}", POOL_NUMBER]
        .iter()
        .chain(reservation)
        .map(|call| scratch(call))
        .collect()
}

fn destroy_calls() -> Vec<String> {
    [
        TABLE,
        "table {scratch}",
        POOL_NUMBER,
        "remove --retry {scratch}",
        "message hyper-pool 0 delete {id}",
    ]
    .iter()
    .map(|call| scratch(call))
    .collect()
}

#[fixture]
fn pool() -> Option<Pool> {
    Pool::new(scratch_dump)
}

macro_rules! require {
    ($pool:expr) => {
        match (is_root(), $pool) {
            (true, Some(pool)) => pool,
            _ => {
                eprintln!("SKIP: needs root and losetup/dmsetup");
                return;
            }
        }
    };
}

#[rstest]
#[case::dump_misses_the_scratch_device(another_devices_dump, "thin device 9 not present")]
#[case::thin_dump_fails(failing_thin_dump, "thin_dump failed: metadata snap not reserved")]
#[case::scratch_device_unreadable(scratch_dump, "No such file or directory")]
fn the_scratch_snapshot_and_reservation_never_outlive_a_failure_as_root(
    #[case] thin_dump: ThinDumpBody,
    #[case] stderr: &str,
) {
    let pool = require!(Pool::new(thin_dump));

    pool.fork_delta(json!({}))
        .failure()
        .stderr(contains(stderr));

    let expected: Vec<String> = [
        pool.snapshot_calls(),
        dump_calls(&[RESERVE, RELEASE]),
        destroy_calls(),
    ]
    .concat();
    assert_eq!(pool.dmsetup_calls(), expected);
}

#[rstest]
#[case::leaked_reservation("stale", true, &[RESERVE, RELEASE, RESERVE, RELEASE])]
#[case::reservation_held("reserved", false, &[RESERVE, RELEASE, RESERVE])]
fn reservation_recovery_still_destroys_the_scratch_as_root(
    pool: Option<Pool>,
    #[case] marker: &str,
    #[case] dumped: bool,
    #[case] reservation: &[&str],
) {
    let pool = require!(pool);
    pool.mark(marker);

    pool.fork_delta(json!({})).failure();

    let expected: Vec<String> = [
        pool.snapshot_calls(),
        dump_calls(reservation),
        destroy_calls(),
    ]
    .concat();
    assert_eq!(pool.dmsetup_calls(), expected);
    assert_eq!(pool.thin_dump_ran(), dumped);
    if let Some(argv) = pool.thin_dump_argv() {
        assert!(
            argv.starts_with(&format!(
                "--metadata-snap --dev-id {SCRATCH_ID} /proc/self/fd/"
            )),
            "{argv}"
        );
    }
}

#[rstest]
fn a_failed_copy_still_removes_the_copy_target_as_root(pool: Option<Pool>) {
    let pool = require!(pool);
    sparse(&pool.base.join("cow.img"), 1 << 20);
    let Some(_scratch) = MapperDevice::linear("hyper-scratch-11", &pool.base.join("origin.img"))
    else {
        eprintln!("SKIP: needs a real scratch device");
        return;
    };

    pool.fork_delta(json!({"scratch_id": 11}))
        .failure()
        .stderr(contains("copying ranges"));

    let target = format!("hyper-copy-{SCRATCH_ID}");
    let calls: Vec<String> = pool
        .dmsetup_calls()
        .into_iter()
        .filter(|call| call.contains(&target))
        .collect();
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(
        calls[0].starts_with(&format!("create {target} --table ")),
        "{calls:?}"
    );
    assert_eq!(calls[1], format!("remove --retry {target}"));
}

#[rstest]
#[case::not_a_thin_pool("linear", &[TABLE])]
#[case::parent_not_a_thin_of_the_pool("parent-linear", &[TABLE, "table hyper-vm1", POOL_NUMBER])]
fn nothing_is_snapshotted_unless_pool_and_parent_check_out_as_root(
    pool: Option<Pool>,
    #[case] marker: &str,
    #[case] calls: &[&str],
) {
    let pool = require!(pool);
    pool.mark(marker);

    pool.fork_delta(json!({})).failure();

    assert_eq!(pool.dmsetup_calls(), calls);
    assert!(!pool.thin_dump_ran());
}

#[rstest]
#[case::system_disk_as_meta(json!({"meta": "/dev/sda"}))]
#[case::traversing_meta(json!({"meta": "/dev/loop0/../sda"}))]
#[case::dm_device_as_meta(json!({"meta": "/dev/mapper/hyper-pool"}))]
#[case::foreign_pool(json!({"pool": "vg0-pool"}))]
#[case::foreign_parent(json!({"parent": "root"}))]
#[case::foreign_origin(json!({"origin": "/dev/mapper/root"}))]
#[case::cow_outside_the_work_dir(json!({"cow": "/etc/passwd"}))]
#[case::scratch_id_past_24_bits(json!({"scratch_id": 16_777_216}))]
#[case::caller_named_source(json!({"src": "/dev/mapper/hyper-a"}))]
#[case::caller_named_target(json!({"dst": "/dev/mapper/hyper-b"}))]
#[case::caller_chosen_chunk_size(json!({"chunk_bytes": 512}))]
fn refuses_before_running_anything_as_root(pool: Option<Pool>, #[case] overrides: Value) {
    let pool = require!(pool);

    pool.fork_delta(overrides.clone()).failure();

    assert!(pool.dmsetup_calls().is_empty(), "{overrides}");
    assert!(!pool.thin_dump_ran(), "{overrides}");
}

fn system_bin(name: &str) -> Option<PathBuf> {
    let out = Command::new("sh")
        .args(["-c", &format!("command -v {name}")])
        .output()
        .ok()?;
    let path = PathBuf::from(String::from_utf8(out.stdout).ok()?.trim());
    fs::canonicalize(path).ok()
}

fn sparse(path: &Path, bytes: u64) {
    fs::File::create(path).unwrap().set_len(bytes).unwrap();
}

#[rstest]
fn forks_exactly_the_parents_provisioned_ranges_into_the_cow_store_as_root() {
    let (Some(dmsetup), Some(thin_dump), true) =
        (system_bin("dmsetup"), system_bin("thin_dump"), is_root())
    else {
        eprintln!("SKIP fork_delta on a real pool: needs root, dmsetup and thin_dump");
        return;
    };
    let dir = TempDir::new().unwrap();
    let base = fs::canonicalize(dir.path()).unwrap();
    let thin_dump = {
        let copy = base.join("thin_dump");
        fs::copy(&thin_dump, &copy).unwrap();
        fs::set_permissions(&copy, fs::Permissions::from_mode(0o755)).unwrap();
        copy
    };
    let config = write_config(&base, &dmsetup, &thin_dump);
    let pid = std::process::id();

    let blocks = 16;
    let size = blocks * BLOCK_BYTES;
    sparse(&base.join("meta.img"), 4 << 20);
    sparse(&base.join("data.img"), 16 << 20);
    fs::write(base.join("origin.img"), vec![0u8; size]).unwrap();
    sparse(&base.join("cow.img"), 4 << 20);

    let (Some(meta), Some(data)) = (
        LoopDevice::attach(&base.join("meta.img")),
        LoopDevice::attach(&base.join("data.img")),
    ) else {
        eprintln!("SKIP fork_delta on a real pool: losetup unavailable");
        return;
    };
    let pool_name = format!("hyper-e2e-pool-{pid}");
    let Some(pool) = DmDevice::create(
        &pool_name,
        &format!("0 32768 thin-pool {} {} 128 0", meta.path(), data.path()),
    ) else {
        eprintln!("SKIP fork_delta on a real pool: dm-thin unavailable");
        return;
    };
    let origin = MapperDevice::linear(&format!("hyper-e2e-origin-{pid}"), &base.join("origin.img"))
        .expect("origin device");
    assert!(pool.message("create_thin 7"), "create_thin on a fresh pool");
    let parent_name = format!("hyper-e2e-parent-{pid}");
    let parent = DmDevice::create(
        &parent_name,
        &format!("0 {} thin {} 7 {}", size / 512, pool.path(), origin.path()),
    )
    .expect("parent thin device");

    let pattern: Vec<u8> = (0..size).map(|i| (i % 251) as u8 + 1).collect();
    let mut expected = vec![0u8; size];
    for (begin, len) in [(0, 3), (9, 1)] {
        use std::io::{Seek, SeekFrom, Write};
        let range = begin * BLOCK_BYTES..(begin + len) * BLOCK_BYTES;
        expected[range.clone()].copy_from_slice(&pattern[range.clone()]);
        let mut dev = fs::OpenOptions::new()
            .write(true)
            .open(parent.path())
            .unwrap();
        dev.seek(SeekFrom::Start(range.start as u64)).unwrap();
        dev.write_all(&pattern[range]).unwrap();
        dev.sync_all().unwrap();
    }

    let out = run(
        &config,
        json!({
            "op": "thin_fork_delta",
            "pool": pool_name,
            "meta": meta.path(),
            "parent": parent_name,
            "scratch_id": REAL_POOL_SCRATCH_ID,
            "origin": origin.path(),
            "cow": base.join("cow.img"),
            "chunk_sectors": 8,
        }),
    )
    .success();

    assert_eq!(stdout_json(&out)["written_chunks"], 2);
    for leftover in [
        format!("hyper-scratch-{REAL_POOL_SCRATCH_ID}"),
        format!("hyper-copy-{REAL_POOL_SCRATCH_ID}"),
    ] {
        assert!(
            !Path::new(&format!("/dev/mapper/{leftover}")).exists(),
            "{leftover} must not outlive the call"
        );
    }
    assert!(
        fs::read(parent.path()).unwrap() == expected,
        "the parent must be untouched and resumed"
    );
    let cow = LoopDevice::attach(&base.join("cow.img")).expect("cow loop");
    let replay = DmDevice::create(
        &format!("hyper-e2e-replay-{pid}"),
        &format!(
            "0 {} snapshot {} {} P 8",
            size / 512,
            origin.path(),
            cow.path()
        ),
    )
    .expect("the cow store replays as a snapshot");
    assert!(
        fs::read(replay.path()).unwrap() == expected,
        "the cow store must hold exactly the parent's divergence over the origin"
    );
}
