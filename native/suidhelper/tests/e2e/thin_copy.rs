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
use support::{is_root, run, stdout_json, MapperDevice};

const BLOCK_SECTORS: u64 = 128;
const BLOCK_BYTES: usize = (BLOCK_SECTORS * 512) as usize;

// One superblock, one device (dev_id=7, 4 mapped blocks: a 3-block range plus
// a single). Extra attributes mirror real thin_dump output; the parser must
// ignore them. mapped_blocks MUST equal the summed lengths or the parser
// refuses as truncated. Kept on one line: the fake emits it via a single
// printf, and line breaks would add whitespace text nodes to the document.
const XML: &str = r#"<superblock uuid="" time="0" transaction="1" data_block_size="128" nr_data_blocks="1000"><device dev_id="7" mapped_blocks="4" transaction="0" creation_time="0" snap_time="0"><range_mapping origin_begin="0" data_begin="100" length="3" time="0"/><single_mapping origin_block="9" data_block="200" time="0"/></device></superblock>"#;

const TABLE: &str = "table hyper-pool";
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

struct Pool {
    dir: TempDir,
    config: PathBuf,
}

impl Pool {
    fn new(thin_dump_body: ThinDumpBody) -> Self {
        let dir = TempDir::new().unwrap();
        let base = dir.path();
        let dmsetup = install(
            base,
            "dmsetup",
            &format!(
                r#"printf '%s\n' "$*" >> '{log}'
case "$1" in
  table)
    if [ -e '{linear}' ]; then printf '0 100 linear 7:0 0\n'; else printf '0 100 thin-pool 7:0 7:1 128 0 0\n'; fi ;;
  message)
    if [ "$4" = reserve_metadata_snap ]; then
      if [ -e '{reserved}' ]; then echo 'reservation exists' >&2; exit 1; fi
      if [ -e '{stale}' ]; then rm '{stale}'; echo 'reservation exists' >&2; exit 1; fi
    fi ;;
esac
"#,
                log = base.join("dmsetup.log").display(),
                linear = base.join("linear").display(),
                reserved = base.join("reserved").display(),
                stale = base.join("stale").display(),
            ),
        );
        let thin_dump = install(base, "thin_dump", &thin_dump_body(base));
        let config = base.join("config.toml");
        fs::write(
            &config,
            format!(
                "work_dir = \"/srv/hyper\"\n[tools]\ndmsetup = \"{}\"\nthin_dump = \"{}\"\n",
                dmsetup.display(),
                thin_dump.display(),
            ),
        )
        .unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o644)).unwrap();
        Self { dir, config }
    }

    fn mark(&self, marker: &str) {
        fs::write(self.dir.path().join(marker), b"").unwrap();
    }

    fn dmsetup_calls(&self) -> Vec<String> {
        fs::read_to_string(self.dir.path().join("dmsetup.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn thin_dump_record(&self) -> Option<String> {
        fs::read_to_string(self.dir.path().join("thin_dump.argv")).ok()
    }

    fn thin_copy(&self, overrides: Value) -> assert_cmd::assert::Assert {
        let mut request = json!({
            "op": "thin_copy",
            "pool": "hyper-pool",
            "meta": "/dev/loop3",
            "thin_id": 7,
            "src": "/dev/mapper/hyper-absent-src",
            "dst": "/dev/mapper/hyper-absent-dst",
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

fn install(dir: &Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[rstest]
fn copies_exactly_the_dumped_ranges_under_a_reservation_as_root(pool: Pool) {
    if !is_root() {
        eprintln!("SKIP thin_copy: needs root");
        return;
    }
    let blocks = 16;
    let src_file = pool.dir.path().join("src.img");
    let dst_file = pool.dir.path().join("dst.img");
    let pattern: Vec<u8> = (0..blocks * BLOCK_BYTES)
        .map(|i| (i % 251) as u8 + 1)
        .collect();
    fs::write(&src_file, &pattern).unwrap();
    fs::write(&dst_file, vec![0u8; pattern.len()]).unwrap();

    let pid = std::process::id();
    let out = {
        let (Some(src), Some(dst)) = (
            MapperDevice::linear(&format!("hyper-e2e-src-{pid}"), &src_file),
            MapperDevice::linear(&format!("hyper-e2e-dst-{pid}"), &dst_file),
        ) else {
            eprintln!("SKIP thin_copy: losetup/dmsetup unavailable");
            return;
        };
        pool.thin_copy(json!({"src": src.path(), "dst": dst.path()}))
            .success()
    };

    assert_eq!(pool.dmsetup_calls(), [TABLE, RESERVE, RELEASE]);
    let record = pool.thin_dump_record().expect("thin_dump ran");
    let mut lines = record.lines();
    let argv = lines.next().unwrap();
    assert!(
        argv.starts_with("--metadata-snap --dev-id 7 /proc/self/fd/"),
        "{argv}"
    );
    assert_eq!(lines.next(), Some("/dev/loop3"));

    let json = stdout_json(&out);
    assert_eq!(json["written_chunks"], 2);
    assert_eq!(json["scanned_chunks"], 2);

    let mut expected = vec![0u8; pattern.len()];
    for (begin, len) in [(0, 3), (9, 1)] {
        let range = begin * BLOCK_BYTES..(begin + len) * BLOCK_BYTES;
        expected[range.clone()].copy_from_slice(&pattern[range]);
    }
    assert!(
        fs::read(&dst_file).unwrap() == expected,
        "dst differs from the ranged oracle"
    );
}

#[rstest]
#[case::wrong_thin_id(recording_thin_dump, json!({"thin_id": 9}), "thin device 9 not present")]
#[case::thin_dump_fails(
    failing_thin_dump,
    json!({}),
    "thin_dump failed: metadata snap not reserved"
)]
#[case::copy_target_missing(recording_thin_dump, json!({}), "No such file or directory")]
fn the_reservation_is_released_on_every_path_that_took_it_as_root(
    #[case] thin_dump: ThinDumpBody,
    #[case] overrides: Value,
    #[case] stderr: &str,
) {
    if !is_root() {
        eprintln!("SKIP thin_copy release: needs root");
        return;
    }
    let pool = Pool::new(thin_dump);

    pool.thin_copy(overrides).failure().stderr(contains(stderr));

    assert_eq!(pool.dmsetup_calls(), [TABLE, RESERVE, RELEASE]);
}

#[rstest]
#[case::leaked_once("stale", true, &[TABLE, RESERVE, RELEASE, RESERVE, RELEASE])]
#[case::reserve_keeps_failing("reserved", false, &[TABLE, RESERVE, RELEASE, RESERVE])]
#[case::not_a_thin_pool("linear", false, &[TABLE])]
fn reservation_recovery_as_root(
    pool: Pool,
    #[case] marker: &str,
    #[case] dumped: bool,
    #[case] calls: &[&str],
) {
    if !is_root() {
        eprintln!("SKIP thin_copy reservation: needs root");
        return;
    }
    pool.mark(marker);

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
#[case::foreign_dst(json!({"dst": "/dev/mapper/root"}))]
#[case::thin_id_past_24_bits(json!({"thin_id": 16_777_216}))]
#[case::caller_chosen_chunk_size(json!({"chunk_bytes": 512}))]
fn refuses_foreign_operands_before_running_anything_as_root(pool: Pool, #[case] overrides: Value) {
    if !is_root() {
        eprintln!("SKIP thin_copy refusal: needs root");
        return;
    }

    pool.thin_copy(overrides.clone()).failure();

    assert!(pool.dmsetup_calls().is_empty(), "{overrides}");
    assert!(pool.thin_dump_record().is_none(), "{overrides}");
}
