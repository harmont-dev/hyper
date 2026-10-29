// SPDX-License-Identifier: MIT
//! Declarative builder for a VM's chroot jail contents.

use crate::config::Config;
use crate::fs::dev::DeviceNumber;
use crate::fs::dir::{self, SafeDir};
use crate::fs::file::{self, Any, IsBlockDevice, IsCharDevice, IsRegularFile, OpenFlags, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, StrictComponent, StrictComponents};
use crate::linux::dm::DmName;
use nix::errno::Errno;
use nix::sys::stat::{Mode, SFlag};
use nix::unistd::{Gid, Uid};
use std::fs::File;
use std::io;
use std::os::unix::io::OwnedFd;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

/// In-jail names — the contract the Elixir side (`Hyper.Node.FireVMM.ChrootJail`)
/// mirrors.
const KERNEL_NAME: &StrictComponent = StrictComponent::from_static("vmlinux");
const ROOTFS_NAME: &StrictComponent = StrictComponent::from_static("rootfs");
const DEV: &StrictComponent = StrictComponent::from_static("dev");
const NET: &StrictComponent = StrictComponent::from_static("net");
const TUN: &StrictComponent = StrictComponent::from_static("tun");

/// `/dev/net/tun`'s well-known major:minor, per Linux's `Documentation/admin-guide/devices.txt`.
const TUN_DEVICE: DeviceNumber = DeviceNumber::new(10, 200);

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Path(#[from] path::ValidationError),
    #[error(transparent)]
    Relative(#[from] path::RelativeError),
    #[error("opening chroot: {0}")]
    OpenChroot(#[source] file::ValidationError),
    #[error("staging kernel: {0}")]
    StageKernel(#[source] dir::Error),
    #[error("opening rootfs device: {0}")]
    Device(#[source] file::ValidationError),
    #[error("creating rootfs node: {0}")]
    MakeRootfs(#[source] dir::Error),
    #[error("creating /dev/net/tun: {0}")]
    MakeTun(#[source] dir::Error),
    #[error("kernel source {path}: {source}")]
    Source {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("kernel source must be under {}: {path}", .base.display())]
    OutsideBase { base: PathBuf, path: PathBuf },
    #[error("open kernel source {path}: {source}")]
    OpenSrc {
        path: PathBuf,
        #[source]
        source: file::ValidationError,
    },
    #[error("copy kernel: {0}")]
    Copy(#[source] io::Error),
    #[error("resolving block device {path}: {source}")]
    ResolveDev {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// An unfilled artifact slot.
pub struct Unset;
/// The kernel slot, carrying its host source path.
pub struct Kernel(PathBuf);
/// The rootfs slot, carrying the block device to mirror.
pub struct Rootfs(DmName);

/// A description of a VM chroot's contents. Type parameters track which slots are
/// filled; see the module docs.
pub struct ChrootJail<K, R> {
    chroot: PathBuf,
    uid: u32,
    gid: u32,
    kernel: K,
    rootfs: R,
}

impl ChrootJail<Unset, Unset> {
    /// A jail at `chroot` (shape `<JAIL_BASE>/<exec>/<id>`), everything owned by
    /// `uid:gid`.
    pub fn new(chroot: impl Into<PathBuf>, uid: u32, gid: u32) -> Self {
        Self {
            chroot: chroot.into(),
            uid,
            gid,
            kernel: Unset,
            rootfs: Unset,
        }
    }
}

impl<R> ChrootJail<Unset, R> {
    /// Stage the guest kernel from host path `source` as `vmlinux`.
    pub fn with_kernel(self, source: impl Into<PathBuf>) -> ChrootJail<Kernel, R> {
        ChrootJail {
            chroot: self.chroot,
            uid: self.uid,
            gid: self.gid,
            kernel: Kernel(source.into()),
            rootfs: self.rootfs,
        }
    }
}

impl<K> ChrootJail<K, Unset> {
    /// Create the rootfs block node as `rootfs`, mirroring `device`.
    pub fn with_rootfs(self, device: DmName) -> ChrootJail<K, Rootfs> {
        ChrootJail {
            chroot: self.chroot,
            uid: self.uid,
            gid: self.gid,
            kernel: self.kernel,
            rootfs: Rootfs(device),
        }
    }
}

impl ChrootJail<Kernel, Rootfs> {
    /// Realize the jail on disk under the configured `JAIL_BASE`/`HYPER_BASE`.
    pub fn build(self) -> Result<(), Error> {
        let cfg = Config::get();
        self.build_under(&cfg.jail_base(), cfg.hyper_base())
    }

    /// Realize the jail relative to explicit base directories: confined walk to
    /// the chroot dir, then stage the kernel and create the rootfs node relative
    /// to that fd. The public [`build`](Self::build) wires `Config` into this.
    pub fn build_under(self, jail_base: &Path, hyper_base: &Path) -> Result<(), Error> {
        let chroot = open_chroot_under(jail_base, &self.chroot)?;
        stage_kernel_under(&chroot, &self.kernel.0, hyper_base, self.uid, self.gid)?;
        make_rootfs(&chroot, &self.rootfs.0, self.uid, self.gid)?;
        if Config::get().network().is_some() {
            make_tun_node(&chroot, self.uid, self.gid).map_err(Error::MakeTun)?;
        }
        Ok(())
    }
}

/// Open the chroot directory by walking it from `jail_base` with `O_NOFOLLOW`, so
/// a symlinked component cannot redirect outside the jail.
pub fn open_chroot_under(jail_base: &Path, chroot: &Path) -> Result<SafeDir, Error> {
    let path: &SafePath<IsAbsolute, StrictComponents> = chroot.try_into()?;
    path.strip_base(jail_base)?;
    SafeDir::open(path, OpenFlags::RDONLY).map_err(Error::OpenChroot)
}

/// Stage host file `src` into `chroot` as `vmlinux`: confine the source under
/// `hyper_base` (after canonicalization), hard-link it (copy across filesystems),
/// then chown to `uid:gid`.
pub fn stage_kernel_under(
    chroot: &SafeDir,
    src: &Path,
    hyper_base: &Path,
    uid: u32,
    gid: u32,
) -> Result<(), Error> {
    let (uid, gid) = (Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid)));

    let src_canon = std::fs::canonicalize(src).map_err(|source| Error::Source {
        path: src.to_path_buf(),
        source,
    })?;
    let src_path: &SafePath<IsAbsolute, StrictComponents> = src_canon.as_path().try_into()?;
    src_path
        .strip_base(hyper_base)
        .map_err(|_| Error::OutsideBase {
            base: hyper_base.to_path_buf(),
            path: src_canon.clone(),
        })?;

    let source = SafeFile::<IsRegularFile, Any, Any>::open(src_path, OpenFlags::RDONLY).map_err(
        |source| Error::OpenSrc {
            path: src_canon.clone(),
            source,
        },
    )?;

    match chroot.linkat(&source, KERNEL_NAME) {
        Ok(()) => source
            .chown(uid, gid)
            .map_err(|e| Error::StageKernel(e.into())),
        Err(Errno::EXDEV) => {
            let mut dest = chroot
                .mkfileat(KERNEL_NAME, Mode::from_bits_truncate(0o600))
                .map_err(|e| Error::StageKernel(e.into()))?;
            io::copy(&mut File::from(OwnedFd::from(source)), &mut dest).map_err(Error::Copy)?;
            dest.chown(uid, gid)
                .map_err(|e| Error::StageKernel(e.into()))
        }
        Err(e) => Err(Error::StageKernel(e.into())),
    }
}

/// Create the `rootfs` block node mirroring `device`'s major:minor, owned
/// `uid:gid`. The device is opened as a verified `SafeFile<IsBlockDevice>`, so the
/// number comes from a real device node, never a caller-supplied value.
fn make_rootfs(chroot: &SafeDir, device: &DmName, uid: u32, gid: u32) -> Result<(), Error> {
    // `device` is lexically validated as `/dev/loopN` or `/dev/mapper/hyper-*`.
    // The dm form is a symlink under `/dev/mapper` — a root-owned `0755` dir an
    // unprivileged caller cannot write — so resolving it to its real `/dev/dm-N`
    // node cannot be redirected by the caller. We must resolve first: `SafeFile`
    // refuses any symlink in the path (it must never follow an attacker-supplied
    // one) and would otherwise reject the dm symlink itself. Loop nodes resolve to
    // themselves. The re-opened target is still verified `IsBlockDevice`.
    let device = device.path();
    let real = std::fs::canonicalize(device.as_path()).map_err(|source| Error::ResolveDev {
        path: device.as_path().to_path_buf(),
        source,
    })?;
    let dev_path: &SafePath<IsAbsolute, StrictComponents> = real.as_path().try_into()?;
    let dev = SafeFile::<IsBlockDevice, Any, Any>::open(dev_path, OpenFlags::PATH)
        .map_err(Error::Device)?;
    let rdev = dev.rdev().map_err(Error::Device)?;
    let make = || -> Result<(), dir::Error> {
        chroot.mknodat(
            ROOTFS_NAME,
            SFlag::S_IFBLK,
            Mode::from_bits_truncate(0o600),
            rdev,
        )?;
        let node: SafeFile<IsBlockDevice, Any, Any> =
            chroot.openat(ROOTFS_NAME, OpenFlags::PATH, Mode::empty())?;
        Ok(node.chown(Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid)))?)
    };
    make().map_err(Error::MakeRootfs)
}

/// Create `dev/net/tun` (char `10:200`, mode `0666`) inside the jail, owned
/// `uid:gid`, so the chrooted firecracker can `open("/dev/net/tun")` and
/// `TUNSETIFF` onto the tap device waiting in its netns. Only called when VM
/// networking is enabled; a jail built without it has no `dev` tree at all
/// today (see [`ChrootJail::build_under`]).
fn make_tun_node(chroot: &SafeDir, uid: u32, gid: u32) -> Result<(), dir::Error> {
    chroot.mkdirat(DEV, Mode::from_bits_truncate(0o755))?;
    let dev_dir: SafeDir = chroot.openat(DEV, OpenFlags::RDONLY, Mode::empty())?;

    dev_dir.mkdirat(NET, Mode::from_bits_truncate(0o755))?;
    let net_dir: SafeDir = dev_dir.openat(NET, OpenFlags::RDONLY, Mode::empty())?;

    match net_dir.mknodat(
        TUN,
        SFlag::S_IFCHR,
        Mode::from_bits_truncate(0o666),
        TUN_DEVICE,
    ) {
        Ok(()) | Err(Errno::EEXIST) => {}
        Err(errno) => return Err(errno.into()),
    }
    let node: SafeFile<IsCharDevice, Any, Any> =
        net_dir.openat(TUN, OpenFlags::PATH, Mode::empty())?;
    node.chown(Some(Uid::from_raw(uid)), Some(Gid::from_raw(gid)))?;
    Ok(node.chmod(Mode::from_bits_truncate(0o666))?)
}
