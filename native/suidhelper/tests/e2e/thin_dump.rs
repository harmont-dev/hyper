//! L4 for `thin-dump`: the helper must pass exactly `--metadata-snap <meta>`
//! to thin_dump (the only safe way to read a live pool), refuse non-loop meta
//! operands at parse time, translate the XML to the ranges JSON, and surface
//! both tool failure and a wrong dev_id as errors — an empty result must never
//! mean "wrong dump".
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

// One superblock, one device (dev_id=7, 4 mapped blocks: a 3-block range plus
// a single). Extra attributes mirror real thin_dump output; the parser must
// ignore them. mapped_blocks MUST equal the summed lengths or the parser
// refuses as truncated. Kept on one line: the fake emits it via a single
// printf, and line breaks would add whitespace text nodes to the document.
const XML: &str = r#"<superblock uuid="" time="0" transaction="1" data_block_size="128" nr_data_blocks="1000"><device dev_id="7" mapped_blocks="4" transaction="0" creation_time="0" snap_time="0"><range_mapping origin_begin="0" data_begin="100" length="3" time="0"/><single_mapping origin_block="9" data_block="200" time="0"/></device></superblock>"#;

/// A root-owned fake `thin_dump` that records its argv into `record` as a JSON
/// array and prints the canned metadata XML.
fn install_fake_thin_dump(dir: &Path, record: &Path) -> PathBuf {
    let path = dir.join("thin_dump");
    let script = format!(
        r#"#!/bin/sh
printf '%s' "$(
  printf '['
  sep=''
  for a in "$@"; do printf '%s"%s"' "$sep" "$a"; sep=','; done
  printf ']'
)" > '{record}'
for last in "$@"; do :; done
readlink "$last" > '{record}.target'
printf '%s\n' '{XML}'
"#,
        record = record.display(),
    );
    fs::write(&path, script).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path // root-owned because these tests run as root
}

fn install_failing_thin_dump(dir: &Path, _record: &Path) -> PathBuf {
    let path = dir.join("thin_dump");
    fs::write(
        &path,
        r"#!/bin/sh
echo 'metadata snap not reserved' >&2
exit 1
",
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn write_root_config(dir: &Path, thin_dump_bin: &Path) -> PathBuf {
    let p = dir.join("config.toml");
    let body = format!(
        r#"work_dir = "/srv/hyper"
[tools]
thin_dump = "{thin_dump}"
"#,
        thin_dump = thin_dump_bin.display(),
    );
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
    p
}

fn recorded_argv(record: &Path) -> Vec<String> {
    let body = fs::read_to_string(record).expect("fake recorded argv");
    serde_json::from_str(&body).expect("argv json")
}

struct Dump {
    tmp: TempDir,
    rec: PathBuf,
}

impl Dump {
    fn config(&self, install: fn(&Path, &Path) -> PathBuf) -> PathBuf {
        let bin = install(self.tmp.path(), &self.rec);
        write_root_config(self.tmp.path(), &bin)
    }
}

#[fixture]
fn dump() -> Dump {
    let tmp = TempDir::new().unwrap();
    let rec = tmp.path().join("argv.json");
    Dump { tmp, rec }
}

#[rstest]
fn thin_dump_argv_and_ranges_json_as_root(dump: Dump) {
    if !is_root() {
        eprintln!("SKIP thin_dump argv: needs root");
        return;
    }
    let cfg = dump.config(install_fake_thin_dump);

    let out = run(
        &cfg,
        &["thin-dump", "--meta", "/dev/loop3", "--dev-id", "7"],
    )
    .success();

    let argv = recorded_argv(&dump.rec);
    assert_eq!(argv[..3], ["--metadata-snap", "--dev-id", "7"], "{argv:?}");
    assert!(argv[3].starts_with("/proc/self/fd/"), "{argv:?}");
    assert_eq!(
        fs::read_to_string(dump.rec.with_extension("json.target"))
            .unwrap()
            .trim(),
        "/dev/loop3",
        "thin_dump must be handed the validated metadata device",
    );

    let json = stdout_json(&out);
    assert_eq!(json["block_sectors"], 128);
    assert_eq!(json["ranges"], serde_json::json!([[0, 3], [9, 1]]));
}

#[rstest]
#[case::wrong_dev_id(install_fake_thin_dump, "9", "thin device 9 not present")]
#[case::child_failure(
    install_failing_thin_dump,
    "7",
    "thin_dump failed: metadata snap not reserved"
)]
fn thin_dump_failure_is_an_error_as_root(
    dump: Dump,
    #[case] install: fn(&Path, &Path) -> PathBuf,
    #[case] dev_id: &str,
    #[case] stderr: &str,
) {
    if !is_root() {
        eprintln!("SKIP thin_dump failure: needs root");
        return;
    }
    let cfg = dump.config(install);

    run(
        &cfg,
        &["thin-dump", "--meta", "/dev/loop3", "--dev-id", dev_id],
    )
    .failure()
    .stderr(contains(stderr));
}

#[rstest]
#[case::not_a_loop("/dev/sda")]
#[case::traversal_from_loop("/dev/loop0/../sda")]
#[case::mapper_device("/dev/mapper/hyper-pool")]
fn thin_dump_refuses_non_loop_meta_as_root(dump: Dump, #[case] bad: &str) {
    if !is_root() {
        eprintln!("SKIP thin_dump meta refusal: needs root");
        return;
    }
    let cfg = dump.config(install_fake_thin_dump);

    run(&cfg, &["thin-dump", "--meta", bad, "--dev-id", "7"]).failure();
    assert!(!dump.rec.exists(), "fake thin_dump ran for refused operand");
}
