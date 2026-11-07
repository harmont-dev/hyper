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
use rstest::{fixture, rstest};
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

struct Base {
    _base_dir: TempDir,
    _outside_dir: TempDir,
    path: PathBuf,
}

#[fixture]
fn base() -> Base {
    let (base_dir, base) = real_tempdir();
    let (outside_dir, outside) = real_tempdir();
    let target = outside.join("target.img");
    std::fs::write(&target, b"x").unwrap();
    let inner = base.join("inner.img");
    std::fs::write(&inner, b"x").unwrap();
    std::fs::create_dir(base.join("sub")).unwrap();
    std::fs::write(base.join("sub/disk.img"), b"x").unwrap();
    std::os::unix::fs::symlink(&target, base.join("escaping.img")).unwrap();
    std::os::unix::fs::symlink(&inner, base.join("in-base.img")).unwrap();
    std::os::unix::fs::symlink(base.join("sub"), base.join("dir-link")).unwrap();
    Base {
        _base_dir: base_dir,
        _outside_dir: outside_dir,
        path: base,
    }
}

#[rstest]
#[case::absent("nope.img")]
#[case::symlink_escaping_the_base("escaping.img")]
#[case::symlink_within_the_base("in-base.img")]
#[case::symlinked_directory_component("dir-link/disk.img")]
#[case::directory("sub")]
fn in_base_path_that_is_not_a_plain_regular_file_is_refused_as_open(
    base: Base,
    #[case] name: &str,
) {
    let err = BackingFile::open(&strict(base.path.join(name)), &strict(&base.path))
        .expect_err("accepted as a backing file");
    assert!(matches!(err, BackingError::Open(_)), "got {err:?}");
}

#[rstest]
fn in_base_file_is_accepted_as_that_inode(base: Base) {
    let backing = base.path.join("sub/disk.img");

    let got = BackingFile::open(&strict(&backing), &strict(&base.path))
        .expect("in-base regular file refused");

    let held = fstat(got.file().as_raw_fd()).unwrap();
    let on_disk = std::fs::metadata(&backing).unwrap();
    assert_eq!((held.st_dev, held.st_ino), (on_disk.dev(), on_disk.ino()));
}
