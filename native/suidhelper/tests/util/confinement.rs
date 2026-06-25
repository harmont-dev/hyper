//! L2: the fd-relative confinement primitives. The security promise is that a
//! symlinked component can never redirect a walk or a recursive delete outside
//! the anchored tree. These run unprivileged in a tempdir; the cases needing
//! root (mknod, chown to another uid) are out of scope here.

use hyper_suidhelper::util::safe_dir::SafeDir;
use hyper_suidhelper::util::safe_file::{
    Any, IsBlockDevice, IsRegularFile, OnlyRootWritable, RootOwner, SafeFile,
};
use hyper_suidhelper::util::safe_path::{IsAbsolute, SafePath, StrictComponents};
use nix::fcntl::OFlag;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};

type Strict = SafePath<IsAbsolute, StrictComponents>;

fn safe(p: &Path) -> Strict {
    p.to_path_buf()
        .try_into()
        .expect("test path must be strict-absolute")
}

// remove_dir_all must unlink a symlinked entry, never follow it: a symlink
// inside the tree pointing at an external sentinel must leave the sentinel and
// its contents intact. This is the core TOCTOU guarantee.
#[test]
fn remove_dir_all_does_not_follow_symlinks_out_of_tree() {
    let tmp = tempfile::tempdir().unwrap();

    // Sentinel OUTSIDE the tree we will delete.
    let sentinel = tmp.path().join("sentinel");
    fs::create_dir(&sentinel).unwrap();
    fs::write(sentinel.join("keep.txt"), b"do not delete me").unwrap();

    // The tree we will recursively remove, containing a symlink to the sentinel.
    let tree = tmp.path().join("tree");
    fs::create_dir(&tree).unwrap();
    fs::write(tree.join("a.txt"), b"x").unwrap();
    symlink(&sentinel, tree.join("escape")).unwrap();

    let anchor = SafeDir::open(&safe(tmp.path())).unwrap();
    anchor.remove_dir_all(Path::new("tree")).unwrap();

    assert!(!tree.exists(), "tree must be gone");
    assert!(sentinel.exists(), "sentinel dir must survive");
    assert!(
        sentinel.join("keep.txt").exists(),
        "sentinel contents must survive"
    );
}

// descend refuses a symlinked path component (O_NOFOLLOW).
#[test]
fn descend_rejects_symlinked_component() {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("real");
    fs::create_dir(&real).unwrap();
    fs::create_dir(real.join("leaf")).unwrap();

    // `link` is a symlink standing in for the `real` directory.
    symlink(&real, tmp.path().join("link")).unwrap();

    let anchor = SafeDir::open(&safe(tmp.path())).unwrap();
    let err = anchor.descend(&[PathBuf::from("link"), PathBuf::from("leaf")]);
    assert!(err.is_err(), "descend followed a symlinked component");
}

// remove_dir_all recurses through real nested directories.
#[test]
fn remove_dir_all_clears_nested_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let tree = tmp.path().join("tree");
    fs::create_dir_all(tree.join("a/b/c")).unwrap();
    fs::write(tree.join("a/b/c/deep.txt"), b"x").unwrap();
    fs::write(tree.join("a/top.txt"), b"y").unwrap();

    let anchor = SafeDir::open(&safe(tmp.path())).unwrap();
    anchor.remove_dir_all(Path::new("tree")).unwrap();
    assert!(!tree.exists());
}

// SafeFile file-type axis: a regular file is not a block device.
#[test]
fn safefile_type_axis_distinguishes_regular_from_block() {
    let tmp = tempfile::tempdir().unwrap();
    let f = tmp.path().join("plain");
    fs::write(&f, b"data").unwrap();

    let p = safe(&f);
    assert!(SafeFile::<IsRegularFile, Any, Any>::open(&p, OFlag::O_PATH).is_ok());
    assert!(SafeFile::<IsBlockDevice, Any, Any>::open(&p, OFlag::O_PATH).is_err());
}

// SafeFile owner axis: a file we (non-root) own fails RootOwner.
#[test]
fn safefile_owner_axis_rejects_non_root_file() {
    let tmp = tempfile::tempdir().unwrap();
    let f = tmp.path().join("ours");
    fs::write(&f, b"data").unwrap();
    let p = safe(&f);
    assert!(SafeFile::<IsRegularFile, RootOwner, Any>::open(&p, OFlag::O_PATH).is_err());
}

// SafeFile mode axis: a group/other-writable file fails OnlyRootWritable.
#[test]
fn safefile_mode_axis_rejects_group_writable() {
    let tmp = tempfile::tempdir().unwrap();
    let f = tmp.path().join("loose");
    fs::write(&f, b"data").unwrap();
    fs::set_permissions(&f, fs::Permissions::from_mode(0o666)).unwrap();
    let p = safe(&f);
    assert!(SafeFile::<IsRegularFile, Any, OnlyRootWritable>::open(&p, OFlag::O_PATH).is_err());

    fs::set_permissions(&f, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(SafeFile::<IsRegularFile, Any, OnlyRootWritable>::open(&p, OFlag::O_PATH).is_ok());
}

// SafeFile::open refuses a symlinked final component (O_NOFOLLOW).
#[test]
fn safefile_open_rejects_final_symlink() {
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("target");
    fs::write(&target, b"data").unwrap();
    let link = tmp.path().join("link");
    symlink(&target, &link).unwrap();
    let p = safe(&link);
    assert!(SafeFile::<IsRegularFile, Any, Any>::open(&p, OFlag::O_PATH).is_err());
}
