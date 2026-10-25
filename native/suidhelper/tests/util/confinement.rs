//! L2: the fd-relative confinement primitives. The security promise is that a
//! symlinked component can never redirect a walk or a recursive delete outside
//! the anchored tree. These run unprivileged in a tempdir; the cases needing
//! root (mknod, chown to another uid) are out of scope here.

use hyper_suidhelper::fs::dir::SafeDir;
use hyper_suidhelper::fs::file::{
    Any, IsBlockDevice, IsDirectory, IsRegularFile, OnlyRootWritable, OpenFlags, RootOwner,
    SafeFile, ValidationError,
};
use hyper_suidhelper::fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use nix::dir::Type;
use nix::errno::Errno;
use nix::sys::stat::Mode;
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::io::Write;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::Path;

type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

fn safe(p: &Path) -> Strict {
    p.to_path_buf()
        .try_into()
        .expect("test path must be strict-absolute")
}

// remove_dir_all must unlink a symlinked entry, never follow it: a symlink
// inside the tree pointing at an external sentinel must leave the sentinel and
// its contents intact. This is the core TOCTOU guarantee.
#[test]
fn rmdirat_recursive_does_not_follow_symlinks_out_of_tree() {
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

    let anchor = SafeDir::open(&safe(tmp.path()), OpenFlags::RDONLY).unwrap();
    anchor.rmdirat_recursive(Path::new("tree")).unwrap();

    assert!(!tree.exists(), "tree must be gone");
    assert!(sentinel.exists(), "sentinel dir must survive");
    assert!(
        sentinel.join("keep.txt").exists(),
        "sentinel contents must survive"
    );
}

// openat never resolves outside its pinned dir or through a symlink, even for a
// multi-component name: the kernel refuses each with its own errno.
#[test]
fn openat_refuses_escape_and_symlinked_components() {
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("outside"), b"x").unwrap();
    let anchor_dir = tmp.path().join("anchor");
    fs::create_dir_all(anchor_dir.join("real")).unwrap();
    fs::write(anchor_dir.join("real/f"), b"x").unwrap();
    symlink(anchor_dir.join("real"), anchor_dir.join("link")).unwrap();

    let anchor = SafeDir::open(&safe(&anchor_dir), OpenFlags::RDONLY).unwrap();
    let outside = tmp.path().join("outside");
    for (name, expected) in [
        (Path::new("../outside"), Errno::EXDEV),
        (outside.as_path(), Errno::EXDEV),
        (Path::new("link/f"), Errno::ELOOP),
        (Path::new("missing"), Errno::ENOENT),
    ] {
        let err = anchor
            .openat::<Any, Any, Any>(name, OpenFlags::PATH, Mode::empty())
            .unwrap_err();
        assert!(
            matches!(err, ValidationError::Open(errno) if errno == expected),
            "{name:?}: {err:?}"
        );
    }
    assert!(anchor
        .openat::<IsRegularFile, Any, Any>(Path::new("real/f"), OpenFlags::PATH, Mode::empty())
        .is_ok());
}

// remove_dir_all recurses through real nested directories.
#[test]
fn rmdirat_recursive_clears_nested_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let tree = tmp.path().join("tree");
    fs::create_dir_all(tree.join("a/b/c")).unwrap();
    fs::write(tree.join("a/b/c/deep.txt"), b"x").unwrap();
    fs::write(tree.join("a/top.txt"), b"y").unwrap();

    let anchor = SafeDir::open(&safe(tmp.path()), OpenFlags::RDONLY).unwrap();
    anchor.rmdirat_recursive(Path::new("tree")).unwrap();
    assert!(!tree.exists());
}

// SafeFile file-type axis: a regular file is not a block device.
#[test]
fn safefile_type_axis_distinguishes_file_types() {
    let tmp = tempfile::tempdir().unwrap();
    let f = tmp.path().join("plain");
    fs::write(&f, b"data").unwrap();

    let p = safe(&f);
    assert!(SafeFile::<IsRegularFile, Any, Any>::open(&p, OpenFlags::PATH).is_ok());
    assert!(SafeFile::<IsBlockDevice, Any, Any>::open(&p, OpenFlags::PATH).is_err());
    assert!(SafeFile::<IsDirectory, Any, Any>::open(&p, OpenFlags::PATH).is_err());

    let d = safe(tmp.path());
    assert!(SafeFile::<IsDirectory, Any, Any>::open(&d, OpenFlags::PATH).is_ok());
    assert!(SafeFile::<IsRegularFile, Any, Any>::open(&d, OpenFlags::PATH).is_err());
}

// SafeFile owner axis: a file we (non-root) own fails RootOwner.
#[test]
fn safefile_owner_axis_rejects_non_root_file() {
    let tmp = tempfile::tempdir().unwrap();
    let f = tmp.path().join("ours");
    fs::write(&f, b"data").unwrap();
    let p = safe(&f);
    assert!(SafeFile::<IsRegularFile, RootOwner, Any>::open(&p, OpenFlags::PATH).is_err());
}

// SafeFile mode axis: a group/other-writable file fails OnlyRootWritable.
#[test]
fn safefile_mode_axis_rejects_group_writable() {
    let tmp = tempfile::tempdir().unwrap();
    let f = tmp.path().join("loose");
    fs::write(&f, b"data").unwrap();
    fs::set_permissions(&f, fs::Permissions::from_mode(0o666)).unwrap();
    let p = safe(&f);
    assert!(SafeFile::<IsRegularFile, Any, OnlyRootWritable>::open(&p, OpenFlags::PATH).is_err());

    fs::set_permissions(&f, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(SafeFile::<IsRegularFile, Any, OnlyRootWritable>::open(&p, OpenFlags::PATH).is_ok());
}

#[test]
fn entries_reports_each_child_with_its_own_type() {
    let tmp = tempfile::tempdir().unwrap();
    fs::write(tmp.path().join("file"), b"x").unwrap();
    fs::create_dir(tmp.path().join("dir")).unwrap();
    symlink(tmp.path().join("dir"), tmp.path().join("link")).unwrap();
    let _sock = UnixListener::bind(tmp.path().join("sock")).unwrap();

    let dir = SafeDir::open(&safe(tmp.path()), OpenFlags::RDONLY).unwrap();
    let got: BTreeMap<OsString, Type> = dir.entries().unwrap().collect::<nix::Result<_>>().unwrap();

    let want = BTreeMap::from([
        (OsString::from("dir"), Type::Directory),
        (OsString::from("file"), Type::File),
        (OsString::from("link"), Type::Symlink),
        (OsString::from("sock"), Type::Socket),
    ]);
    assert_eq!(got, want);
}

#[test]
fn safefile_write_all_writes_through_the_fd() {
    let tmp = tempfile::tempdir().unwrap();
    let f = tmp.path().join("f");
    fs::write(&f, b"x").unwrap();

    let dir = SafeDir::open(&safe(tmp.path()), OpenFlags::RDONLY).unwrap();
    let mut file: SafeFile<Any, Any, Any> = dir
        .openat(
            Path::new("f"),
            OpenFlags::WRONLY | OpenFlags::TRUNC,
            Mode::empty(),
        )
        .unwrap();
    file.write_all(b"hello").unwrap();
    assert_eq!(fs::read(&f).unwrap(), b"hello");
}

// SafeFile::open refuses a symlink in any component with ELOOP. The `Any` type
// axis means a followed (or `O_PATH`-held) symlink would otherwise succeed, so
// only the kernel's resolve refusal can make this pass.
#[test]
fn safefile_open_rejects_symlink_in_any_component() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("dir");
    fs::create_dir(&dir).unwrap();
    fs::write(dir.join("target"), b"data").unwrap();
    symlink(dir.join("target"), tmp.path().join("final_link")).unwrap();
    symlink(&dir, tmp.path().join("parent_link")).unwrap();

    for (case, path) in [
        ("final", tmp.path().join("final_link")),
        ("parent", tmp.path().join("parent_link/target")),
    ] {
        for flags in [OpenFlags::PATH, OpenFlags::RDONLY] {
            let res = SafeFile::<Any, Any, Any>::open(&safe(&path), flags);
            assert!(
                matches!(res, Err(ValidationError::Open(Errno::ELOOP))),
                "{case} symlink with {flags:?}: {res:?}"
            );
        }
    }
}
