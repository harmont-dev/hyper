// SPDX-License-Identifier: AGPL-3.0-only
//! Declarative builder for a VM's chroot jail contents.

use crate::config::Config;
use crate::util::safe_dev::BlockDev;
use crate::util::safe_dir::{self, SafeDir};
use crate::util::safe_file::{self, Any, IsBlockDevice, SafeFile};
use crate::util::safe_path::{self, IsAbsolute, SafePath, StrictComponents};
use nix::errno::Errno;
use nix::fcntl::{open as nix_open, OFlag};
use nix::sys::stat::Mode;
use std::io;
use std::os::unix::io::FromRawFd;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

/// In-jail names — the contract the Elixir side (`Hyper.Node.FireVMM.ChrootJail`)
/// mirrors.
const KERNEL_NAME: &str = "vmlinux";
const ROOTFS_NAME: &str = "rootfs";

#[derive(Debug, ThisError)]
pub enum Error {
    #[error(transparent)]
    Path(#[from] safe_path::ValidationError),
    #[error(transparent)]
    Fs(#[from] safe_dir::Error),
    #[error(transparent)]
    Device(#[from] safe_file::ValidationError),
    #[error("kernel source {path}: {source}")]
    Source {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("kernel source must be under {}: {path}", .base.display())]
    OutsideBase { base: &'static Path, path: PathBuf },
    #[error("open kernel source {path}: {source}")]
    OpenSrc {
        path: PathBuf,
        #[source]
        source: nix::Error,
    },
    #[error("copy kernel: {0}")]
    Copy(#[source] io::Error),
}

/// An unfilled artifact slot.
pub struct Unset;
/// The kernel slot, carrying its host source path.
pub struct Kernel(PathBuf);
/// The rootfs slot, carrying the block device to mirror.
pub struct Rootfs(BlockDev);

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
    pub fn with_rootfs(self, device: BlockDev) -> ChrootJail<K, Rootfs> {
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
    /// Realize the jail on disk: confined walk to the chroot dir, then stage the
    /// kernel and create the rootfs node relative to that fd.
    pub fn build(self) -> Result<(), Error> {
        let chroot = open_chroot(&self.chroot)?;
        stage_kernel(&chroot, &self.kernel.0, self.uid, self.gid)?;
        make_rootfs(&chroot, &self.rootfs.0, self.uid, self.gid)?;
        Ok(())
    }
}

/// Open the chroot directory by walking it from `JAIL_BASE` with `O_NOFOLLOW`, so
/// a symlinked component cannot redirect outside the jail.
fn open_chroot(chroot: &Path) -> Result<SafeDir, Error> {
    let jail_base = Config::get().jail_base();
    let path: SafePath<IsAbsolute, StrictComponents> = chroot.to_path_buf().try_into()?;
    let (parents, leaf) = path.relative_to(&jail_base)?;
    let anchor: SafePath<IsAbsolute, StrictComponents> = jail_base.try_into()?;

    let mut components = parents;
    components.push(leaf);
    Ok(SafeDir::open(&anchor)?.descend(&components)?)
}

/// Stage host file `src` into `chroot` as `vmlinux`: confine the source under
/// `HYPER_BASE`, hard-link it (copy across filesystems), then chown to `uid:gid`.
fn stage_kernel(chroot: &SafeDir, src: &Path, uid: u32, gid: u32) -> Result<(), Error> {
    let kernel = Path::new(KERNEL_NAME);
    let src_canon = std::fs::canonicalize(src).map_err(|source| Error::Source {
        path: src.to_path_buf(),
        source,
    })?;
    let base = Config::get().hyper_base();
    if !src_canon.starts_with(base) {
        return Err(Error::OutsideBase {
            base,
            path: src_canon,
        });
    }

    match chroot.link_from(&src_canon, kernel) {
        Ok(()) => {}
        // Cross-filesystem: open the confined source O_RDONLY|O_NOFOLLOW, create
        // the dest O_CREAT|O_EXCL|O_NOFOLLOW, and copy. Both fds are RAII.
        Err(safe_dir::Error::Link { source, .. }) if source == Errno::EXDEV => {
            let src_raw = nix_open(
                &src_canon,
                OFlag::O_RDONLY | OFlag::O_NOFOLLOW | OFlag::O_CLOEXEC,
                Mode::empty(),
            )
            .map_err(|source| Error::OpenSrc {
                path: src_canon.clone(),
                source,
            })?;
            // SAFETY: nix_open just handed us this fd; File owns and closes it.
            let mut src_file = unsafe { std::fs::File::from_raw_fd(src_raw) };

            let dest = chroot.create_file(kernel, 0o600)?;
            let mut dest_file = std::fs::File::from(dest.into_owned_fd());

            io::copy(&mut src_file, &mut dest_file).map_err(Error::Copy)?;
        }
        Err(e) => return Err(Error::Fs(e)),
    }

    chroot.chown(kernel, uid, gid)?;
    Ok(())
}

/// Create the `rootfs` block node mirroring `device`'s major:minor, owned
/// `uid:gid`. The device is opened as a verified `SafeFile<IsBlockDevice>`, so the
/// number comes from a real device node, never a caller-supplied value.
fn make_rootfs(chroot: &SafeDir, device: &BlockDev, uid: u32, gid: u32) -> Result<(), Error> {
    let dev_path: SafePath<IsAbsolute, StrictComponents> = device.as_ref().to_path_buf().try_into()?;
    let dev = SafeFile::<IsBlockDevice, Any, Any>::open(&dev_path, OFlag::O_PATH)?;
    let rdev = dev.rdev()?;
    chroot.mknod_block(Path::new(ROOTFS_NAME), rdev, uid, gid)?;
    Ok(())
}
