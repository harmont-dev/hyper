// SPDX-License-Identifier: MIT
//! Confinement contract of [`SafeDir`]: fd-anchored operations never act through a planted link
//! and never reach outside the anchor.
//!
//! Laws under test:
//! - **`openat` is lexical-beneath.** For any relative name built from real dirs, `.` and `..`,
//!   the open succeeds iff the walk never climbs above the anchor (oracle: running depth never
//!   negative); a climb is always `EXDEV`, never a successful open of something outside.
//! - **Planted names are refused, never followed.** `mkfileat` over any existing entry (file,
//!   dir, symlink to a file outside, dangling symlink to a path outside) is `EEXIST` and creates or
//!   writes nothing outside; `ensure_dir` over a symlink-to-dir or a file is an error and creates
//!   nothing in the link's target; `make_device` over a planted non-device or symlink is refused
//!   without chowning/chmodding the planted file or the link's target.
//! - **`entries` is the directory listing.** For any set of names the kernel accepts (any bytes
//!   but `/` and NUL, whitespace and non-UTF-8 included), it reports exactly those names.
//! - **`rmdirat_recursive` removes the whole tree and only the tree.** For any tree of dirs, files
//!   and symlinks pointing outside, the tree is gone afterwards and everything outside is intact,
//!   whatever bytes the entry names hold (spaces, newlines and non-UTF-8 bytes are legal names a
//!   tree can contain); a target that is itself a symlink is refused and nothing is removed.

use assert_fs::TempDir;
use hyperrs_fs::dev::{DeviceNode, DeviceNumber};
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{Any, IsBlockDevice, IsDirectory, OpenFlags, Owner, ValidationError};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponent, StrictComponents};
use nix::errno::Errno;
use nix::sys::stat::Mode;
use proptest::prelude::*;
use std::assert_matches;
use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

fn open(p: &Path) -> SafeDir {
    let strict: Strict = p.to_path_buf().try_into().expect("strict tmp path");
    SafeDir::open(&strict, OpenFlags::RDONLY).unwrap()
}

fn name(s: &str) -> &StrictComponent {
    s.try_into().unwrap()
}

fn mode_of(p: &Path) -> u32 {
    fs::symlink_metadata(p).unwrap().mode() & 0o7777
}

struct World {
    _tmp: TempDir,
    anchor: PathBuf,
    outside_file: PathBuf,
    outside_dir: PathBuf,
    outside_absent: PathBuf,
}

impl World {
    fn new() -> Self {
        let tmp = TempDir::new().unwrap();
        let anchor = tmp.path().join("anchor");
        fs::create_dir(&anchor).unwrap();
        let outside_file = tmp.path().join("outside-file");
        fs::write(&outside_file, b"outside").unwrap();
        fs::set_permissions(&outside_file, fs::Permissions::from_mode(0o640)).unwrap();
        let outside_dir = tmp.path().join("outside-dir");
        fs::create_dir(&outside_dir).unwrap();
        fs::write(outside_dir.join("keep"), b"keep").unwrap();
        Self {
            outside_absent: tmp.path().join("outside-absent"),
            _tmp: tmp,
            anchor,
            outside_file,
            outside_dir,
        }
    }

    fn assert_outside_intact(&self) {
        assert_eq!(fs::read(&self.outside_file).unwrap(), b"outside");
        assert_eq!(mode_of(&self.outside_file), 0o640);
        let listing: Vec<_> = fs::read_dir(&self.outside_dir)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(listing, [OsString::from("keep")]);
        assert_eq!(fs::read(self.outside_dir.join("keep")).unwrap(), b"keep");
        assert!(fs::symlink_metadata(&self.outside_absent).is_err());
    }

    fn plant(&self, how: Plant, at: &Path) {
        match how {
            Plant::File => fs::write(at, b"planted").unwrap(),
            Plant::Dir => fs::create_dir(at).unwrap(),
            Plant::LinkToFile => symlink(&self.outside_file, at).unwrap(),
            Plant::LinkToDir => symlink(&self.outside_dir, at).unwrap(),
            Plant::Dangling => symlink(&self.outside_absent, at).unwrap(),
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum Plant {
    File,
    Dir,
    LinkToFile,
    LinkToDir,
    Dangling,
}

const PLANTS: [Plant; 5] = [
    Plant::File,
    Plant::Dir,
    Plant::LinkToFile,
    Plant::LinkToDir,
    Plant::Dangling,
];

#[test]
fn mkfileat_refuses_every_planted_name_and_writes_nothing_outside() {
    for plant in PLANTS {
        let w = World::new();
        w.plant(plant, &w.anchor.join("victim"));
        assert_matches!(
            open(&w.anchor).mkfileat(name("victim"), Mode::from_bits_truncate(0o644)),
            Err(ValidationError::Open(Errno::EEXIST)),
            "{plant:?}"
        );
        w.assert_outside_intact();
    }
}

#[test]
fn ensure_dir_never_resolves_a_planted_link_or_file() {
    for plant in [
        Plant::File,
        Plant::LinkToDir,
        Plant::LinkToFile,
        Plant::Dangling,
    ] {
        let w = World::new();
        let at = w.anchor.join("victim");
        w.plant(plant, &at);
        let got = open(&w.anchor)
            .ensure_dir(name("victim"), Mode::from_bits_truncate(0o700))
            .and_then(|dir| dir.ensure_dir(name("child"), Mode::from_bits_truncate(0o700)));
        assert!(got.is_err(), "{plant:?}");
        assert!(!fs::symlink_metadata(&at).unwrap().is_dir(), "{plant:?}");
        w.assert_outside_intact();
    }
}

#[test]
fn make_device_never_adopts_a_planted_non_device() {
    let me = Owner::caller();
    for plant in [Plant::File, Plant::Dir, Plant::LinkToFile, Plant::Dangling] {
        let w = World::new();
        let at = w.anchor.join("rootfs");
        w.plant(plant, &at);
        let before = fs::symlink_metadata(&at).unwrap();
        let node = DeviceNode::<IsBlockDevice>::new(
            DeviceNumber::new(7, 0),
            Mode::from_bits_truncate(0o666),
        );
        let got = open(&w.anchor).make_device(name("rootfs"), node, me);
        assert!(got.is_err(), "{plant:?}");
        let after = fs::symlink_metadata(&at).unwrap();
        assert_eq!(after.mode(), before.mode(), "{plant:?}");
        assert_eq!(after.file_type(), before.file_type(), "{plant:?}");
        w.assert_outside_intact();
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Step {
    Into(&'static str),
    Dot,
    Up,
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        3 => prop::sample::select(vec!["a", "b"]).prop_map(Step::Into),
        1 => Just(Step::Dot),
        2 => Just(Step::Up),
    ]
}

fn stays_beneath(steps: &[Step]) -> bool {
    let mut depth = 0i32;
    for s in steps {
        match s {
            Step::Into(_) => depth += 1,
            Step::Dot => {}
            Step::Up => depth -= 1,
        }
        if depth < 0 {
            return false;
        }
    }
    true
}

fn build_nested(root: &Path, depth: usize) {
    if depth == 0 {
        return;
    }
    for d in ["a", "b"] {
        let child = root.join(d);
        fs::create_dir(&child).unwrap();
        build_nested(&child, depth - 1);
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn openat_succeeds_iff_the_walk_stays_beneath_the_anchor(
        steps in prop::collection::vec(step(), 1..7),
    ) {
        let tmp = TempDir::new().unwrap();
        let outer = tmp.path().join("a");
        fs::create_dir(&outer).unwrap();
        let anchor = outer.join("a");
        fs::create_dir(&anchor).unwrap();
        build_nested(&anchor, 6);

        let rel: PathBuf = steps
            .iter()
            .map(|s| match s {
                Step::Into(d) => *d,
                Step::Dot => ".",
                Step::Up => "..",
            })
            .collect();
        let got = open(&anchor).openat::<IsDirectory, Any, Any>(&rel, OpenFlags::PATH, Mode::empty());
        if stays_beneath(&steps) {
            prop_assert!(got.is_ok(), "{rel:?}: {got:?}");
        } else {
            prop_assert!(matches!(got, Err(ValidationError::Open(Errno::EXDEV))), "{rel:?}: {got:?}");
        }
    }

    #[test]
    fn entries_lists_exactly_the_created_names(
        names in prop::collection::btree_set(prop::collection::vec(1u8..=255, 1..12), 0..12),
    ) {
        let names: BTreeSet<OsString> = names
            .into_iter()
            .filter(|n| !n.contains(&b'/') && n != b"." && n != b"..")
            .map(|n| OsStr::from_bytes(&n).to_os_string())
            .collect();
        let tmp = TempDir::new().unwrap();
        for (i, n) in names.iter().enumerate() {
            let p = tmp.path().join(n);
            if i % 2 == 0 { fs::write(p, b"").unwrap() } else { fs::create_dir(p).unwrap() }
        }
        let got: BTreeSet<OsString> = open(tmp.path())
            .entries()
            .unwrap()
            .map(|e| e.map(|(n, _)| n.as_os_str().to_os_string()))
            .collect::<nix::Result<_>>()
            .unwrap();
        prop_assert_eq!(got, names);
    }
}

#[derive(Debug, Clone)]
enum Node {
    File,
    Link(Plant),
    Dir(Vec<Node>),
}

fn node() -> impl Strategy<Value = Node> {
    let leaf = prop_oneof![
        2 => Just(Node::File),
        1 => prop::sample::select(vec![Plant::LinkToFile, Plant::LinkToDir, Plant::Dangling]).prop_map(Node::Link),
    ];
    leaf.prop_recursive(4, 24, 4, |inner| {
        prop::collection::vec(inner, 0..4).prop_map(Node::Dir)
    })
}

fn entry_name() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        4 => "[a-z]{1,6}".prop_map(String::into_bytes),
        1 => Just(vec![0xff, 0xfe, b'x']),
        1 => Just(b".hidden".to_vec()),
    ]
}

fn materialize(w: &World, node: &Node, at: &Path, names: &mut impl Iterator<Item = Vec<u8>>) {
    match node {
        Node::File => fs::write(at, b"x").unwrap(),
        Node::Link(plant) => w.plant(*plant, at),
        Node::Dir(children) => {
            fs::create_dir(at).unwrap();
            for (i, child) in children.iter().enumerate() {
                let mut raw = names.next().unwrap();
                raw.extend(format!("{i}").bytes());
                materialize(w, child, &at.join(OsStr::from_bytes(&raw)), names);
            }
        }
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn rmdirat_recursive_removes_the_tree_and_only_the_tree(
        children in prop::collection::vec(node(), 0..4),
        names in prop::collection::vec(entry_name(), 64),
    ) {
        let w = World::new();
        let tree = w.anchor.join("tree");
        materialize(&w, &Node::Dir(children.clone()), &tree, &mut names.into_iter().cycle());

        let got = open(&w.anchor).rmdirat_recursive(name("tree"));
        prop_assert!(got.is_ok(), "{children:?}: {got:?}");
        prop_assert!(fs::symlink_metadata(&tree).is_err());
        w.assert_outside_intact();
    }
}

#[test]
fn rmdirat_recursive_removes_trees_holding_any_legal_entry_name() {
    let names: [&[u8]; 5] = [
        b"two words",
        b"line\nbreak",
        b"tab\there",
        b"trailing ",
        b"\xff\xfe",
    ];
    let failures: Vec<String> = names
        .iter()
        .filter_map(|raw| {
            let tmp = TempDir::new().unwrap();
            let tree = tmp.path().join("tree");
            fs::create_dir(&tree).unwrap();
            fs::write(tree.join(OsStr::from_bytes(raw)), b"x").unwrap();
            let got = open(tmp.path()).rmdirat_recursive(name("tree"));
            (got.is_err() || tree.exists())
                .then(|| format!("{:?}: {got:?}", String::from_utf8_lossy(raw)))
        })
        .collect();
    assert!(failures.is_empty(), "tree not removed for {failures:#?}");
}

#[test]
fn rmdirat_recursive_refuses_a_symlinked_target_and_removes_nothing() {
    let w = World::new();
    let link = w.anchor.join("tree");
    symlink(&w.outside_dir, &link).unwrap();
    assert_matches!(
        open(&w.anchor).rmdirat_recursive(name("tree")),
        Err(e) if e.errno() == Some(Errno::ELOOP)
    );
    assert!(fs::symlink_metadata(&link)
        .unwrap()
        .file_type()
        .is_symlink());
    w.assert_outside_intact();
}
