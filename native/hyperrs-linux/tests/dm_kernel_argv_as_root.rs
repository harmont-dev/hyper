//! The live counterpart of `dm_kernel_argv_properties`: a table `Dmsetup`
//! creates must make the kernel open the very device each path operand names.
//! Law: for a `DevPath` the type accepts, the dm device built over it is
//! backed by that path's device, never by a different file whose name is a
//! prefix of it. Root only: it attaches loop devices and creates a dm device.

#![feature(adt_const_params, unsized_const_params)]
#![allow(incomplete_features)]

use assert_fs::TempDir;
use hyperrs_fs::file::{Any, IsRegularFile, OpenFlags, SafeFile};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use hyperrs_linux::dm::{DevPath, DmName, DmTable, Dmsetup, LinearTable, Origin, RemoveMode};
use hyperrs_linux::loopdev::{LoopControl, LoopDevice};
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBin;
use pretty_assertions::assert_eq;
use rstest::rstest;
use std::ffi::OsStr;
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{symlink, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const DMSETUP: &str = "/usr/sbin/dmsetup";

fn attach(file: &Path) -> LoopDevice {
    fs::File::create(file).unwrap().set_len(1 << 20).unwrap();
    let path: SafePathBuf<IsAbsolute, StrictComponents> = file.to_path_buf().try_into().unwrap();
    let backing = SafeFile::<IsRegularFile, Any, Any>::open(&path, OpenFlags::PATH).unwrap();
    LoopControl::open()
        .unwrap()
        .attach(&backing, Access::ReadOnly, Duration::from_secs(2))
        .unwrap()
}

fn major_minor(dev: &Path) -> String {
    let rdev = fs::metadata(dev).unwrap().rdev();
    format!(
        "{}:{}",
        nix::sys::stat::major(rdev),
        nix::sys::stat::minor(rdev)
    )
}

struct Removing(String);

impl Drop for Removing {
    fn drop(&mut self) {
        let _ = Command::new(DMSETUP)
            .args(["remove", "--retry", &self.0])
            .output();
    }
}

#[rstest]
#[case::copyright_sign(b"x\xc2\xa9", b"x\xc2")]
#[case::latin_e_acute(b"\xc3\xa9", b"\xc3")]
fn a_linear_table_is_backed_by_the_path_it_names_as_root(
    #[case] named: &[u8],
    #[case] prefix: &[u8],
) {
    if !nix::unistd::geteuid().is_root() {
        eprintln!("SKIP: needs root");
        return;
    }
    let dir = TempDir::new().unwrap();
    let base = fs::canonicalize(dir.path()).unwrap();
    let wanted = attach(&base.join("wanted.img"));
    let decoy = attach(&base.join("decoy.img"));
    let named = base.join(OsStr::from_bytes(named));
    symlink(wanted.path().as_path(), &named).unwrap();
    symlink(decoy.path().as_path(), base.join(OsStr::from_bytes(prefix))).unwrap();

    let origin: DevPath = PathBuf::from(&named)
        .try_into()
        .expect("the type accepts it");
    let dm = Dmsetup::new(RootSafeBin::open(Path::new(DMSETUP)).unwrap());
    let name: DmName = format!("hyperrs-argv-{}", std::process::id())
        .parse()
        .unwrap();
    let _guard = Removing(name.to_string());
    let table = DmTable::Linear(LinearTable {
        sectors: 8,
        origin: Origin::Path(origin),
    });
    let device = dm.create(&name, &table, Access::ReadOnly).unwrap();

    let live = Command::new(DMSETUP)
        .args(["table", &name.to_string()])
        .output()
        .unwrap();
    let live = String::from_utf8(live.stdout).unwrap();
    device.remove(RemoveMode::Retry).unwrap();
    assert_eq!(
        live.split_whitespace().nth(3),
        Some(major_minor(wanted.path().as_path()).as_str()),
        "the kernel opened {} (decoy is {}) for {named:?}",
        live.trim(),
        major_minor(decoy.path().as_path()),
    );
}
