// SPDX-License-Identifier: MIT

use crate::firecracker::id::JailOwner;
use crate::firecracker::jailer::VmId;
use crate::fs::dev::DeviceNode;
use crate::fs::dir::{self, SafeDir};
use crate::fs::file::{self, Any, IsBlockDevice, IsRegularFile, IsSocket, OpenFlags, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponents};
use crate::linux::tun;
use nix::errno::Errno;
use nix::sys::stat::Mode;
use nix::unistd::{getgid, getuid};
use serde::Serialize;
use std::io;
use std::path::PathBuf;
use thiserror::Error as ThisError;

/// In-jail names — the contract the Elixir side (`Hyper.Node.FireVMM.ChrootJail`)
/// mirrors.
const KERNEL_NAME: &StrictComponent = StrictComponent::from_static("vmlinux");
const ROOTFS_NAME: &StrictComponent = StrictComponent::from_static("rootfs");
const ROOT_NAME: &StrictComponent = StrictComponent::from_static("root");

const KERNEL_MODE: Mode = Mode::from_bits_truncate(0o444);
const ROOTFS_MODE: Mode = Mode::from_bits_truncate(0o600);
const DIR_MODE: Mode = Mode::from_bits_truncate(0o755);

/// Mode handed to the node: owner+group read/write, no world access.
const SOCKET_MODE: Mode = Mode::from_bits_truncate(0o660);

/// Mode set on the jail `root` dir so the node's group can traverse it to
/// reach the socket: owner `rwx`, group `--x` (traverse, not list), other none.
const JAIL_ROOT_MODE: Mode = Mode::from_bits_truncate(0o710);

#[derive(Debug, ThisError)]
pub enum OpenError {
    #[error(transparent)]
    Base(#[from] path::RelativeError),
    #[error("jail root must be exactly <exec>/<vm id>/root below the jail base: {0:?}")]
    Shape(PathBuf),
    #[error("opening jail root: {0}")]
    Open(#[from] file::ValidationError),
}

#[derive(Debug, ThisError)]
pub enum KernelError {
    #[error("resolving kernel source {path:?}: {source}")]
    Resolve {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error(transparent)]
    Path(#[from] path::ValidationError),
    #[error("kernel source must be under {base:?}: {path:?}")]
    OutsideBase { base: PathBuf, path: PathBuf },
    #[error("opening kernel source {path:?}: {source}")]
    Open {
        path: PathBuf,
        #[source]
        source: file::ValidationError,
    },
}

/// Result type shared by all `chroot-jail grant-*` ops.
#[derive(Debug, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum GrantOut {
    /// The socket was handed to the caller (chowned + chmoded).
    Granted,
    /// The socket does not exist yet; the caller should keep waiting.
    Pending,
}

#[derive(Debug, ThisError)]
pub enum GrantError {
    #[error("not a socket (or is a symlink); refusing to touch it")]
    NotASocket,
    #[error("statting the socket: {0}")]
    Stat(#[source] file::ValidationError),
    #[error("chowning the socket to the caller: {0}")]
    Chown(#[source] Errno),
    #[error("chmoding the socket: {0}")]
    Chmod(#[source] Errno),
    #[error("chgrp-ing the jail root dir to the caller: {0}")]
    ChgrpRoot(#[source] Errno),
    #[error("chmoding the jail root dir for traversal: {0}")]
    ChmodRoot(#[source] Errno),
}

pub struct KernelImage(SafeFile<IsRegularFile, Any, Any>);

impl KernelImage {
    pub fn open(
        path: &SafePath<IsAbsolute, StrictComponents>,
        hyper_base: &SafePath<IsAbsolute, StrictComponents>,
    ) -> Result<Self, KernelError> {
        let real =
            std::fs::canonicalize(path.as_path()).map_err(|source| KernelError::Resolve {
                path: path.as_path().to_path_buf(),
                source,
            })?;
        let real: SafePathBuf<IsAbsolute, StrictComponents> = real.try_into()?;
        real.strip_base(hyper_base)
            .map_err(|_| KernelError::OutsideBase {
                base: hyper_base.as_path().to_path_buf(),
                path: real.as_path().to_path_buf(),
            })?;
        let file =
            SafeFile::open(&real, OpenFlags::RDONLY).map_err(|source| KernelError::Open {
                path: real.as_path().to_path_buf(),
                source,
            })?;
        Ok(Self(file))
    }
}

pub struct JailRoot(SafeDir);

impl JailRoot {
    pub fn open(
        jail_base: &SafePath<IsAbsolute, StrictComponents>,
        path: &SafePath<IsAbsolute, StrictComponents>,
    ) -> Result<Self, OpenError> {
        let mut segments = path.strip_base(jail_base)?.segments();
        let shape_ok = match (
            segments.next(),
            segments.next(),
            segments.next(),
            segments.next(),
        ) {
            (Some(_exec), Some(id), Some(root), None) => {
                root == ROOT_NAME
                    && id
                        .as_os_str()
                        .to_str()
                        .is_some_and(|id| id.parse::<VmId>().is_ok())
            }
            _ => false,
        };
        if !shape_ok {
            return Err(OpenError::Shape(path.as_path().to_path_buf()));
        }
        Ok(Self(SafeDir::open(path, OpenFlags::RDONLY)?))
    }

    pub fn stage_kernel(&self, kernel: KernelImage) -> Result<(), dir::Error> {
        self.0.link_or_copy(kernel.0, KERNEL_NAME, KERNEL_MODE)
    }

    pub fn add_rootfs<R, O>(
        &self,
        device: &SafeFile<IsBlockDevice, R, O>,
        owner: JailOwner,
    ) -> Result<(), dir::Error> {
        let node = DeviceNode::<IsBlockDevice>::new(device.rdev()?, ROOTFS_MODE);
        self.0.make_device(ROOTFS_NAME, node, owner.into())?;
        Ok(())
    }

    pub fn add_tun(&self, owner: JailOwner) -> Result<(), dir::Error> {
        let net = self
            .0
            .ensure_dir(tun::DEV, DIR_MODE)?
            .ensure_dir(tun::NET, DIR_MODE)?;
        net.make_device(tun::NAME, tun::NODE, owner.into())?;
        Ok(())
    }

    /// Stat `leaf` under the jail root (`AT_SYMLINK_NOFOLLOW`), verify it is a real
    /// socket (`S_IFSOCK`; a symlink reports `S_IFLNK` and is refused), then chown it
    /// to the caller and chmod `0660`. Also open the jail root for the caller's
    /// group to traverse (chgrp'd to the caller, chmod'd `0710`) so the node can
    /// reach the socket even though the jailer left `root` at `0700`. Returns
    /// `Pending` if `leaf` is not yet present (`ENOENT`).
    pub fn grant_to_caller(&self, leaf: &StrictComponent) -> Result<GrantOut, GrantError> {
        let sock: SafeFile<IsSocket, Any, Any> =
            match self.0.openat(leaf, OpenFlags::PATH, Mode::empty()) {
                Ok(sock) => sock,
                Err(file::ValidationError::Open(Errno::ENOENT)) => return Ok(GrantOut::Pending),
                Err(
                    file::ValidationError::Open(Errno::ELOOP)
                    | file::ValidationError::WrongFileType,
                ) => return Err(GrantError::NotASocket),
                Err(e) => return Err(GrantError::Stat(e)),
            };
        sock.chown(Some(getuid()), Some(getgid()))
            .map_err(GrantError::Chown)?;
        sock.chmod(SOCKET_MODE).map_err(GrantError::Chmod)?;
        self.0
            .chown(None, Some(getgid()))
            .map_err(GrantError::ChgrpRoot)?;
        self.0
            .chmod(JAIL_ROOT_MODE)
            .map_err(GrantError::ChmodRoot)?;
        Ok(GrantOut::Granted)
    }
}
