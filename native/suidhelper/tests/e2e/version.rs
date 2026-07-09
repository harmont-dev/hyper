//! L5: the `version` self-report contract. The Elixir side
//! (`Hyper.SuidHelper.Expected`) parses this JSON line and compares
//! `checksum_blake3` against the expected stamp, so any shape drift here
//! breaks helper verification at install time.
//!
//! Contract under test: exit 0 with a single JSON object on stdout where
//! `version` == the crate version and `checksum_blake3` is 32 bytes of
//! lowercase hex (all-zero on an unstamped dev build -- shape, not value).
#![cfg(feature = "insecure_test_seams")]

use std::path::Path;

mod support;

#[test]
fn version_reports_pkg_version_and_hex_checksum() {
    // A nonexistent config path: `version` renders before config setup,
    // so it must succeed regardless. Needs no root.
    let out = support::run(Path::new("/nonexistent/hyper-config.toml"), &["version"]);
    assert_eq!(
        out.status.code(),
        Some(0),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let json: serde_json::Value = serde_json::from_slice(&out.stdout).expect("stdout is JSON");
    assert_eq!(json["version"], env!("CARGO_PKG_VERSION"));
    let sum = json["checksum_blake3"]
        .as_str()
        .expect("checksum is a string");
    assert_eq!(sum.len(), 64, "BLAKE3 is 32 bytes -> 64 hex chars");
    assert!(
        sum.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
        "checksum must be lowercase hex, got: {sum}"
    );
}
