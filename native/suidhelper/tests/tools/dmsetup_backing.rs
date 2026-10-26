//! Contracts of `BackingFile::open`, the confinement gate for every file a dm
//! table names. Laws:
//!   * a path that does not canonicalize (absent file) is refused as
//!     `Canonicalize`, never accepted;
//!   * an existing path whose resolved real location is outside the base is
//!     ALWAYS refused as `OutsideBase`, regardless of the spelling used to
//!     reach it (direct, symlink, `..` traversal, in-base symlink);
//!   * an in-base regular file is accepted as a handle to exactly that inode;
//!   * anything in-base that is not a regular file is refused.

use hyper_suidhelper::tools::{BackingError, BackingFile};
use nix::sys::stat::fstat;
use proptest::prelude::*;
use std::os::unix::fs::MetadataExt;
use std::os::unix::io::AsRawFd;
use std::path::PathBuf;
use tempfile::TempDir;

fn real_tempdir() -> (TempDir, PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let real = std::fs::canonicalize(tmp.path()).unwrap();
    (tmp, real)
}

proptest! {
    #[test]
    fn any_existing_file_outside_base_is_refused(
        name in "[A-Za-z0-9][A-Za-z0-9._-]{0,31}",
    ) {
        let (_base_dir, base) = real_tempdir();
        let (_outside_dir, outside) = real_tempdir();
        let p = outside.join(&name);
        std::fs::write(&p, b"x").unwrap();

        let err = BackingFile::open(&p, &base).expect_err("out-of-base backing file accepted");
        prop_assert!(matches!(err, BackingError::OutsideBase { .. }), "got {err:?}");
    }
}

#[test]
fn absent_path_is_refused_as_canonicalize() {
    let (_base_dir, base) = real_tempdir();

    let err = BackingFile::open(&base.join("nope.img"), &base).expect_err("absent file accepted");
    assert!(
        matches!(err, BackingError::Canonicalize { .. }),
        "got {err:?}"
    );
}

#[test]
fn refusal_is_decided_on_the_resolved_path() {
    let (_base_dir, base) = real_tempdir();
    let (_outside_dir, outside) = real_tempdir();
    let target = outside.join("target.img");
    std::fs::write(&target, b"x").unwrap();

    let outer_link = outside.join("link.img");
    std::os::unix::fs::symlink(&target, &outer_link).unwrap();
    let inner_link = base.join("innocent.img");
    std::os::unix::fs::symlink(&target, &inner_link).unwrap();
    std::fs::create_dir(base.join("sub")).unwrap();
    let dotdot = base
        .join("sub/../..")
        .join(outside.file_name().unwrap())
        .join("target.img");

    for spelling in [outer_link, inner_link, dotdot] {
        let err = BackingFile::open(&spelling, &base).expect_err("out-of-base spelling accepted");
        assert!(
            matches!(err, BackingError::OutsideBase { .. }),
            "{}: got {err:?}",
            spelling.display(),
        );
    }
}

#[test]
fn in_base_file_is_accepted_as_that_inode() {
    let (_base_dir, base) = real_tempdir();
    let backing = base.join("disk.img");
    std::fs::write(&backing, b"data").unwrap();

    let got = BackingFile::open(&backing, &base).expect("in-base regular file refused");

    let held = fstat(got.file().as_raw_fd()).unwrap();
    let on_disk = std::fs::metadata(&backing).unwrap();
    assert_eq!((held.st_dev, held.st_ino), (on_disk.dev(), on_disk.ino()));
}

#[test]
fn directory_under_base_is_refused() {
    let (_base_dir, base) = real_tempdir();
    let dir = base.join("subdir");
    std::fs::create_dir(&dir).unwrap();

    let err = BackingFile::open(&dir, &base).expect_err("directory accepted as backing file");
    assert!(matches!(err, BackingError::Open(_)), "got {err:?}");
}
