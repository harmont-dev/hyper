//! The end-to-end contract the helper's install-time verification rests on:
//! the digest `Elf::stamp` writes into a built executable is exactly what
//! `checksum!()` reports when that executable runs, and a verifier that
//! re-zeroes `.note.sum` and BLAKE3-hashes the file recomputes it. Laws:
//!   * runtime report == stamped digest (the stamper patched the slot the
//!     loader maps, and the read is not constant-folded to the link-time zero);
//!   * re-zero + rehash of the stamped file == stamped digest;
//!   * an unstamped executable reports all zeroes.
#![cfg(all(target_os = "linux", feature = "stamp"))]

use hyperrs_elfsum::Elf;
use pretty_assertions::assert_eq;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

const CHILD: &str = "HYPER_ELFSUM_REPORT_SLOT";
const TEST: &str = "a_stamped_executable_reports_its_own_stamp_at_runtime";

fn hex(d: &[u8]) -> String {
    d.iter().map(|b| format!("{b:02x}")).collect()
}

fn report(exe: &Path) -> String {
    let out = Command::new(exe)
        .args(["--exact", TEST, "--nocapture", "--test-threads=1"])
        .env(CHILD, "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    let stdout = String::from_utf8(out.stdout).unwrap();
    stdout
        .split_once("slot=")
        .and_then(|(_, rest)| rest.get(..64))
        .unwrap_or_else(|| panic!("child printed no slot: {stdout}"))
        .to_string()
}

#[test]
fn a_stamped_executable_reports_its_own_stamp_at_runtime() {
    if std::env::var_os(CHILD).is_some() {
        println!("slot={}", hyperrs_elfsum::checksum!().hex());
        return;
    }
    let dir = std::env::temp_dir().join(format!("elfsum-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let original = fs::read("/proc/self/exe").unwrap();

    let unstamped = dir.join("unstamped");
    fs::write(&unstamped, &original).unwrap();
    fs::set_permissions(&unstamped, fs::Permissions::from_mode(0o755)).unwrap();
    assert_eq!(report(&unstamped), "0".repeat(64));

    let mut bytes = original.clone();
    let digest = Elf::read(&mut bytes[..]).unwrap().stamp();
    let stamped = dir.join("stamped");
    fs::write(&stamped, &bytes).unwrap();
    fs::set_permissions(&stamped, fs::Permissions::from_mode(0o755)).unwrap();

    assert_eq!(report(&stamped), hex(&digest));

    let changed: Vec<usize> = (0..bytes.len())
        .filter(|&i| bytes[i] != original[i])
        .collect();
    let (first, last) = (changed[0], *changed.last().unwrap());
    assert!(
        last - first < digest.len(),
        "stamp touched bytes outside one slot"
    );
    let at = (0..=bytes.len() - digest.len())
        .find(|&i| bytes[i..i + digest.len()] == digest)
        .unwrap();
    let mut rezeroed = bytes.clone();
    rezeroed[at..at + digest.len()].fill(0);
    assert_eq!(*blake3::hash(&rezeroed).as_bytes(), digest);

    fs::remove_dir_all(&dir).unwrap();
}
