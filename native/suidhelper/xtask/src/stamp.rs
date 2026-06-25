//! Checksum stamping: the post-link step cargo has no native hook for.
//!
//! BLAKE3-hashes the release ELF with the `.note.sum` section zeroed, then
//! writes that digest back into the section. The binary reports it via
//! `hyper-suidhelper version`; a verifier re-zeroes the section, rehashes, and
//! compares.

use std::path::PathBuf;

use hyper_suidhelper_meta::{CHECKSUM_LEN, CHECKSUM_SECTION as SECTION};
use object::{Object, ObjectSection};

use crate::{target_dir, BIN};

/// Build the release binary and stamp its checksum section. Returns the path to
/// the stamped ELF.
pub fn run() -> PathBuf {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let built = std::process::Command::new(cargo)
        .args(["build", "--release", "-p", BIN])
        .status()
        .expect("failed to spawn cargo");
    assert!(built.success(), "cargo build --release failed");

    let path = target_dir().join("release").join(BIN);
    let mut bytes = std::fs::read(&path).expect("failed to read release binary");

    let (offset, size) = section_range(&bytes);
    assert_eq!(size, CHECKSUM_LEN, "{SECTION} must be {CHECKSUM_LEN} bytes");

    // Zero the slot before hashing so the digest is reproducible whether or not
    // the binary was already stamped (re-running stamp is idempotent).
    bytes[offset..offset + size].fill(0);
    let digest = blake3::hash(&bytes);
    bytes[offset..offset + size].copy_from_slice(digest.as_bytes());

    std::fs::write(&path, &bytes).expect("failed to write stamped binary");
    println!("stamped {} -> {}", path.display(), digest.to_hex());
    path
}

/// File offset and size of the checksum section in the given ELF image.
fn section_range(bytes: &[u8]) -> (usize, usize) {
    let elf = object::File::parse(bytes).expect("failed to parse ELF");
    let section = elf
        .section_by_name(SECTION)
        .unwrap_or_else(|| panic!("{SECTION} section not found — is checksum.rs linked in?"));
    let (offset, size) = section
        .file_range()
        .expect("checksum section has no file range");
    (offset as usize, size as usize)
}
