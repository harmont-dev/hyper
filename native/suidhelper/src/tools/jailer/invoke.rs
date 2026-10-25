// SPDX-License-Identifier: MIT
//! The `execve` hand-off to the firecracker jailer: build its exact argv from
//! trusted config plus already-validated caller arguments, become root
//! permanently, and replace this process image.

use super::args::{CgroupSetting, JailSock, MAX_CGROUPS};
use super::cstr::ToCStringExt;
use super::Error;
use crate::privilege;
use crate::vm::{JailId, VmId};
use bon::Builder;
use std::ffi::CString;
use std::path::Path;

/// A fully-resolved jailer invocation. The privileged fields (`jailer`,
/// `firecracker`, `jail_base`, `parent_cgroup`) must come from trusted config;
/// the caller-supplied fields (`vm`, `uid`, `gid`, `cgroups`, `api_sock`) must
/// already have passed their newtype validation.
#[derive(Builder)]
pub struct Jailer<'a> {
    jailer: &'a Path,
    firecracker: &'a Path,
    jail_base: &'a Path,
    parent_cgroup: &'a str,
    vm: &'a VmId,
    uid: JailId,
    gid: JailId,
    cgroups: &'a [CgroupSetting],
    api_sock: &'a JailSock,
    /// The netns the jailer must enter (`--netns`), `Some` when VM networking is
    /// enabled. Derived by the caller from trusted config + the validated `vm`
    /// id — never from caller input — and must match the `ip netns add <id>`
    /// path the `network` tool creates.
    netns: Option<&'a Path>,
}

impl Jailer<'_> {
    /// Build the exact argv handed to the jailer. argv[0] is the jailer path. The
    /// caller never names the jailer, the `--exec-file`, the chroot base, the
    /// cgroup version, or the parent cgroup — those come from trusted config.
    fn argv(&self) -> Result<Vec<CString>, Error> {
        let mut argv = vec![
            self.jailer.to_cstring()?,
            "--id".to_cstring()?,
            self.vm.to_string().to_cstring()?,
            "--exec-file".to_cstring()?,
            self.firecracker.to_cstring()?,
            "--uid".to_cstring()?,
            self.uid.to_string().to_cstring()?,
            "--gid".to_cstring()?,
            self.gid.to_string().to_cstring()?,
            "--chroot-base-dir".to_cstring()?,
            self.jail_base.to_cstring()?,
            "--cgroup-version".to_cstring()?,
            "2".to_cstring()?,
            "--parent-cgroup".to_cstring()?,
            self.parent_cgroup.to_cstring()?,
        ];

        for cg in self.cgroups {
            argv.push("--cgroup".to_cstring()?);
            argv.push(cg.to_string().to_cstring()?);
        }

        if let Some(netns) = self.netns {
            argv.push("--netns".to_cstring()?);
            argv.push(netns.to_cstring()?);
        }

        argv.push("--".to_cstring()?);
        argv.push("--api-sock".to_cstring()?);
        argv.push(self.api_sock.to_string().to_cstring()?);

        Ok(argv)
    }

    /// Permanently become root and `execve` the jailer in our place. On success
    /// this never returns (the process image is replaced); the `Ok` arm is
    /// therefore [`std::convert::Infallible`]. Every failure is returned as
    /// [`Error`] for the caller to print and exit non-zero.
    pub fn invoke(self) -> Result<std::convert::Infallible, Error> {
        if self.cgroups.len() > MAX_CGROUPS {
            return Err(Error::TooManyCgroups(self.cgroups.len()));
        }

        // Resolve everything that can fail before any privilege is raised.
        let argv = self.argv()?;
        let jailer_cstr = self.jailer.to_cstring()?;

        // Point of no return: from here we are permanently root and must execve.
        privilege::become_root_permanently()?;
        close_inherited_fds();

        // Empty envp: once ruid==0 the kernel clears AT_SECURE, so a smuggled
        // LD_PRELOAD/LD_LIBRARY_PATH would be honored by the dynamic loader and
        // hijack the root jailer. We pass nothing and let the jailer build its own.
        let empty_env: [CString; 0] = [];
        let errno = nix::unistd::execve(&jailer_cstr, &argv, &empty_env)
            .expect_err("execve only returns on failure");
        Err(Error::Exec {
            path: self.jailer.to_path_buf(),
            errno,
        })
    }
}

/// Close every inherited fd above stdio so a compromised BEAM cannot smuggle an
/// open fd into the root jailer. Keep 0/1/2: MuonTrap supervises the jailer
/// through stdio, and stderr carries our exec-failure message. `close_range(2)`
/// needs Linux 5.9+; on any failure (ENOSYS or otherwise) we fall back to
/// closing each fd individually — fail closed before handing root to the jailer.
fn close_inherited_fds() {
    const FIRST: u32 = 3;
    // Invoke `close_range(2)` as a raw syscall rather than through the
    // `libc::close_range` wrapper: the `libc` crate does not define that wrapper
    // for every target (it is absent on aarch64-musl), but `SYS_close_range` is
    // defined on all Linux arches. `syscall` returns 0 on success, -1 on error.
    // SAFETY: raw syscall with no memory operands; closing fds has no UB.
    let rc = unsafe {
        nix::libc::syscall(
            nix::libc::SYS_close_range,
            FIRST as nix::libc::c_uint,
            u32::MAX as nix::libc::c_uint,
            0 as nix::libc::c_uint,
        )
    };
    if rc == 0 {
        return;
    }

    // SAFETY: sysconf is a pure query of a system limit.
    let max = unsafe { nix::libc::sysconf(nix::libc::_SC_OPEN_MAX) };
    let max = if max < 0 { 4096 } else { max as i32 };
    for fd in (FIRST as i32)..max {
        // SAFETY: closing an arbitrary fd is safe; EBADF for unused fds is ignored.
        unsafe {
            nix::libc::close(fd);
        }
    }
}
