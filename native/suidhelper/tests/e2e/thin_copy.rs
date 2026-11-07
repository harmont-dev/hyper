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

// One superblock, one device (dev_id=7, 4 mapped blocks: a 3-block range plus
// a single). Extra attributes mirror real thin_dump output; the parser must
// ignore them. mapped_blocks MUST equal the summed lengths or the parser
// refuses as truncated. Kept on one line: the fake emits it via a single
// printf, and line breaks would add whitespace text nodes to the document.
const XML: &str = r#"<superblock uuid="" time="0" transaction="1" data_block_size="128" nr_data_blocks="1000"><device dev_id="7" mapped_blocks="4" transaction="0" creation_time="0" snap_time="0"><range_mapping origin_begin="0" data_begin="100" length="3" time="0"/><single_mapping origin_block="9" data_block="200" time="0"/></device></superblock>"#;

const TABLE: &str = "table hyper-pool";
const SOURCE: &str = "table hyper-absent-src";
const POOL_NUMBER: &str = "info -c --noheadings -o major,minor hyper-pool";
const RESERVE: &str = "message hyper-pool 0 reserve_metadata_snap";
const RELEASE: &str = "message hyper-pool 0 release_metadata_snap";

type ThinDumpBody = fn(&Path) -> String;

fn recording_thin_dump(base: &Path) -> String {
    format!(
        r#"printf '%s\n' "$*" > '{record}'
for last in "$@"; do :; done
readlink "$last" >> '{record}'
printf '%s\n' '{XML}'
"#,
        record = base.join("thin_dump.argv").display(),
    )
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
}

impl Pool {
    fn new(thin_dump_body: ThinDumpBody) -> Self {
        let dir = TempDir::new().unwrap();
        let base = fs::canonicalize(dir.path()).unwrap();
        let dmsetup = install(
            &base,
            "dmsetup",
            &format!(
                r#"printf '%s\n' "$*" >> '{b}/dmsetup.log'
case "$1" in
  table)
    if [ "$2" = hyper-pool ]; then
      if [ -e '{b}/linear' ]; then printf '0 100 linear 7:0 0\n'; else printf '0 100 thin-pool 7:0 7:1 128 0 0\n'; fi
    elif [ -e '{b}/src-linear' ]; then printf '0 2048 linear 7:0 0\n'
    else printf '0 2048 thin 253:1 %s\n' "$(cat '{b}/src-id' 2>/dev/null || echo 7)"; fi ;;
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
        let config = write_config(&base, &dmsetup, &thin_dump);
        Self {
            _dir: dir,
            base,
            config,
        }
    }

    fn mark(&self, marker: &str, contents: &str) {
        fs::write(self.base.join(marker), contents).unwrap();
    }

    fn dmsetup_calls(&self) -> Vec<String> {
        fs::read_to_string(self.base.join("dmsetup.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn thin_dump_record(&self) -> Option<String> {
        fs::read_to_string(self.base.join("thin_dump.argv")).ok()
    }

    fn thin_copy(&self, overrides: Value) -> assert_cmd::assert::Assert {
        let mut request = json!({
            "op": "thin_copy",
            "pool": "hyper-pool",
            "meta": "/dev/loop3",
            "src": "/dev/mapper/hyper-absent-src",
            "origin": "/dev/mapper/hyper-absent-origin",
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

#[fixture]
fn pool() -> Pool {
    Pool::new(recording_thin_dump)
}

#[rstest]
#[case::wrong_thin_id(recording_thin_dump, "9", "thin device 9 not present")]
#[case::thin_dump_fails(failing_thin_dump, "7", "thin_dump failed: metadata snap not reserved")]
#[case::copy_source_missing(recording_thin_dump, "7", "No such file or directory")]
fn the_reservation_is_released_on_every_path_that_took_it_as_root(
    #[case] thin_dump: ThinDumpBody,
    #[case] src_id: &str,
    #[case] stderr: &str,
) {
    if !is_root() {
        eprintln!("SKIP thin_copy release: needs root");
        return;
    }
    let pool = Pool::new(thin_dump);
    pool.mark("src-id", src_id);

    pool.thin_copy(json!({})).failure().stderr(contains(stderr));

    assert_eq!(
        pool.dmsetup_calls(),
        [TABLE, SOURCE, POOL_NUMBER, RESERVE, RELEASE]
    );
}

#[rstest]
#[case::leaked_once("stale", true, &[TABLE, SOURCE, POOL_NUMBER, RESERVE, RELEASE, RESERVE, RELEASE])]
#[case::reserve_keeps_failing("reserved", false, &[TABLE, SOURCE, POOL_NUMBER, RESERVE, RELEASE, RESERVE])]
#[case::not_a_thin_pool("linear", false, &[TABLE])]
#[case::source_not_a_thin_of_the_pool("src-linear", false, &[TABLE, SOURCE, POOL_NUMBER])]
fn reservation_and_source_checks_as_root(
    pool: Pool,
    #[case] marker: &str,
    #[case] dumped: bool,
    #[case] calls: &[&str],
) {
    if !is_root() {
        eprintln!("SKIP thin_copy reservation: needs root");
        return;
    }
    pool.mark(marker, "");

    pool.thin_copy(json!({})).failure();

    assert_eq!(pool.dmsetup_calls(), calls);
    assert_eq!(pool.thin_dump_record().is_some(), dumped);
}

#[rstest]
#[case::system_disk_as_meta(json!({"meta": "/dev/sda"}))]
#[case::traversing_meta(json!({"meta": "/dev/loop0/../sda"}))]
#[case::dm_device_as_meta(json!({"meta": "/dev/mapper/hyper-pool"}))]
#[case::relative_meta(json!({"meta": "loop3"}))]
#[case::foreign_pool(json!({"pool": "vg0-pool"}))]
#[case::foreign_src(json!({"src": "/dev/sda"}))]
#[case::foreign_origin(json!({"origin": "/dev/mapper/root"}))]
#[case::cow_outside_the_work_dir(json!({"cow": "/etc/passwd"}))]
#[case::caller_chosen_chunk_size(json!({"chunk_bytes": 512}))]
#[case::caller_named_target(json!({"dst": "/dev/mapper/hyper-b"}))]
#[case::caller_named_thin_id(json!({"thin_id": 7}))]
fn refuses_before_running_anything_as_root(pool: Pool, #[case] overrides: Value) {
    if !is_root() {
        eprintln!("SKIP thin_copy refusal: needs root");
        return;
    }

    pool.thin_copy(overrides.clone()).failure();

    assert!(pool.dmsetup_calls().is_empty(), "{overrides}");
    assert!(pool.thin_dump_record().is_none(), "{overrides}");
}

fn dmsetup_path() -> Option<PathBuf> {
    let out = Command::new("sh")
        .args(["-c", "command -v dmsetup"])
        .output()
        .ok()?;
    let path = PathBuf::from(String::from_utf8(out.stdout).ok()?.trim());
    fs::canonicalize(path).ok()
}

fn sparse(path: &Path, bytes: u64) {
    fs::File::create(path).unwrap().set_len(bytes).unwrap();
}

#[rstest]
fn copies_exactly_the_provisioned_ranges_into_the_cow_store_as_root() {
    let Some(dmsetup) = dmsetup_path().filter(|_| is_root()) else {
        eprintln!("SKIP thin_copy into a real pool: needs root and dmsetup");
        return;
    };
    let dir = TempDir::new().unwrap();
    let base = fs::canonicalize(dir.path()).unwrap();
    let thin_dump = install(&base, "thin_dump", &recording_thin_dump(&base));
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
        eprintln!("SKIP thin_copy into a real pool: losetup unavailable");
        return;
    };
    let pool_name = format!("hyper-e2e-pool-{pid}");
    let Some(pool) = DmDevice::create(
        &pool_name,
        &format!("0 32768 thin-pool {} {} 128 0", meta.path(), data.path()),
    ) else {
        eprintln!("SKIP thin_copy into a real pool: dm-thin unavailable");
        return;
    };
    assert!(pool.message("create_thin 7"), "create_thin on a fresh pool");
    let src = DmDevice::create(
        &format!("hyper-e2e-src-{pid}"),
        &format!("0 {} thin {} 7", size / 512, pool.path()),
    )
    .expect("thin device");
    let origin = MapperDevice::linear(&format!("hyper-e2e-origin-{pid}"), &base.join("origin.img"))
        .expect("origin device");

    let pattern: Vec<u8> = (0..size).map(|i| (i % 251) as u8 + 1).collect();
    let mut provisioned = vec![0u8; size];
    for (begin, len) in [(0, 3), (9, 1)] {
        let range = begin * BLOCK_BYTES..(begin + len) * BLOCK_BYTES;
        provisioned[range.clone()].copy_from_slice(&pattern[range]);
    }
    for (begin, len) in [(0, 3), (9, 1)] {
        use std::io::{Seek, SeekFrom, Write};
        let mut dev = fs::OpenOptions::new().write(true).open(src.path()).unwrap();
        dev.seek(SeekFrom::Start((begin * BLOCK_BYTES) as u64))
            .unwrap();
        dev.write_all(&provisioned[begin * BLOCK_BYTES..(begin + len) * BLOCK_BYTES])
            .unwrap();
        dev.sync_all().unwrap();
    }

    let out = run(
        &config,
        json!({
            "op": "thin_copy",
            "pool": pool_name,
            "meta": meta.path(),
            "src": src.path(),
            "origin": origin.path(),
            "cow": base.join("cow.img"),
            "chunk_sectors": 8,
        }),
    )
    .success();

    assert_eq!(stdout_json(&out)["written_chunks"], 2);
    assert!(
        !Path::new("/dev/mapper/hyper-copy-7").exists(),
        "the copy target must not outlive the call"
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
        fs::read(replay.path()).unwrap() == provisioned,
        "the cow store must hold exactly the provisioned ranges over the origin"
    );
}
