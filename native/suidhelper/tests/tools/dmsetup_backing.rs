//! Contracts of `BackingFile::open`, the confinement gate for every file a dm
//! table names. Laws:
//!   * a path not lexically under the base is ALWAYS refused as `OutsideBase`;
//!   * an in-base path that is absent, or reaches through any symlink, is
//!     refused as `Open`, never followed;
//!   * an in-base regular file is accepted as a handle to exactly that inode;
//!   * anything in-base that is not a regular file is refused.

use hyper_suidhelper::tools::{BackingError, BackingFile};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use nix::sys::stat::fstat;
use proptest::prelude::*;
use std::os::unix::fs::MetadataExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

fn strict(p: impl AsRef<Path>) -> SafePathBuf<IsAbsolute, StrictComponents> {
    p.as_ref().to_path_buf().try_into().unwrap()
}

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

        let err = BackingFile::open(&strict(&p), &strict(&base)).expect_err("out-of-base backing file accepted");
        prop_assert!(matches!(err, BackingError::OutsideBase { .. }), "got {err:?}");
    }
}

#[test]
fn absent_path_is_refused_as_open() {
    let (_base_dir, base) = real_tempdir();

    let err = BackingFile::open(&strict(base.join("nope.img")), &strict(&base))
        .expect_err("absent file accepted");
    assert!(matches!(err, BackingError::Open(_)), "got {err:?}");
}

#[test]
fn a_symlink_is_never_followed() {
    let (_base_dir, base) = real_tempdir();
    let (_outside_dir, outside) = real_tempdir();
    let target = outside.join("target.img");
    std::fs::write(&target, b"x").unwrap();
    let inner = base.join("inner.img");
    std::fs::write(&inner, b"x").unwrap();
    std::fs::create_dir(base.join("sub")).unwrap();

    let escaping = base.join("escaping.img");
    std::os::unix::fs::symlink(&target, &escaping).unwrap();
    let in_base = base.join("in-base.img");
    std::os::unix::fs::symlink(&inner, &in_base).unwrap();
    let dir_link = base.join("dir-link");
    std::os::unix::fs::symlink(base.join("sub"), &dir_link).unwrap();
    std::fs::write(base.join("sub/disk.img"), b"x").unwrap();

    for spelling in [escaping, in_base, dir_link.join("disk.img")] {
        let err = BackingFile::open(&strict(&spelling), &strict(&base))
            .expect_err("symlinked spelling accepted");
        assert!(
            matches!(err, BackingError::Open(_)),
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

    let got =
        BackingFile::open(&strict(&backing), &strict(&base)).expect("in-base regular file refused");

    let held = fstat(got.file().as_raw_fd()).unwrap();
    let on_disk = std::fs::metadata(&backing).unwrap();
    assert_eq!((held.st_dev, held.st_ino), (on_disk.dev(), on_disk.ino()));
}

#[test]
fn directory_under_base_is_refused() {
    let (_base_dir, base) = real_tempdir();
    let dir = base.join("subdir");
    std::fs::create_dir(&dir).unwrap();

    let err = BackingFile::open(&strict(&dir), &strict(&base))
        .expect_err("directory accepted as backing file");
    assert!(matches!(err, BackingError::Open(_)), "got {err:?}");
}
