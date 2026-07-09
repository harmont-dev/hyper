//! L4 for `thin-dump`: the helper must pass exactly `--metadata-snap <meta>`
//! to thin_dump (the only safe way to read a live pool), refuse non-loop meta
//! operands at parse time, translate the XML to the ranges JSON, and surface
//! both tool failure and a wrong dev_id as errors — an empty result must never
//! mean "wrong dump".
#![cfg(feature = "insecure_test_seams")]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

mod support;
use support::{is_root, run};

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
printf '%s\n' '{XML}'
"#,
        record = record.display(),
    );
    fs::write(&path, script).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path // root-owned because these tests run as root
}

fn install_failing_thin_dump(dir: &Path) -> PathBuf {
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

#[test]
fn thin_dump_argv_and_ranges_json_as_root() {
    if !is_root() {
        eprintln!("SKIP thin_dump argv: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake_thin_dump(tmp.path(), &rec);
    let cfg = write_root_config(tmp.path(), &bin);

    let out = run(
        &cfg,
        &["thin-dump", "--meta", "/dev/loop3", "--dev-id", "7"],
    );
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    assert_eq!(recorded_argv(&rec), vec!["--metadata-snap", "/dev/loop3"]);

    let json: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(json["block_sectors"], 128);
    assert_eq!(json["ranges"], serde_json::json!([[0, 3], [9, 1]]));
}

#[test]
fn thin_dump_wrong_dev_id_is_an_error_as_root() {
    if !is_root() {
        eprintln!("SKIP thin_dump dev_id: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake_thin_dump(tmp.path(), &rec);
    let cfg = write_root_config(tmp.path(), &bin);

    let out = run(
        &cfg,
        &["thin-dump", "--meta", "/dev/loop3", "--dev-id", "9"],
    );
    assert_ne!(
        out.status.code(),
        Some(0),
        "an absent dev_id must be an error, never an empty result",
    );
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("thin device 9 not present"), "stderr: {err}");
}

#[test]
fn thin_dump_child_failure_surfaces_its_stderr_as_root() {
    if !is_root() {
        eprintln!("SKIP thin_dump failure arm: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let bin = install_failing_thin_dump(tmp.path());
    let cfg = write_root_config(tmp.path(), &bin);

    let out = run(
        &cfg,
        &["thin-dump", "--meta", "/dev/loop3", "--dev-id", "7"],
    );
    assert_ne!(out.status.code(), Some(0));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("thin_dump failed: metadata snap not reserved"),
        "stderr: {err}",
    );
}

#[test]
fn thin_dump_refuses_non_loop_meta_as_root() {
    if !is_root() {
        eprintln!("SKIP thin_dump meta refusal: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let rec = tmp.path().join("argv.json");
    let bin = install_fake_thin_dump(tmp.path(), &rec);
    let cfg = write_root_config(tmp.path(), &bin);

    for bad in ["/dev/sda", "/dev/loop0/../sda", "/dev/mapper/hyper-pool"] {
        let out = run(&cfg, &["thin-dump", "--meta", bad, "--dev-id", "7"]);
        assert_ne!(out.status.code(), Some(0), "meta accepted {bad}");
        assert!(
            !rec.exists(),
            "fake thin_dump ran for refused operand {bad}"
        );
    }
}
