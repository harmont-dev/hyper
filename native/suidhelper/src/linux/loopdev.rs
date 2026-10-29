//! Utilities for interacting with `/dev/loop-control`.
use super::Access;
use crate::fs::dev::DeviceNumber;
use crate::fs::file::{self, Any, IsBlockDevice, IsCharDevice, IsRegularFile, OpenFlags, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, SafePathBuf, StrictComponents};
use derive_more::{Display, From};
use nix::errno::Errno;
use smart_default::SmartDefault;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::time::{Duration, Instant};
use thiserror::Error as ThisError;

const CONTROL_PATH: &str = "/dev/loop-control";
const DEVICE_PREFIX: &str = "/dev/loop";
const LOOP_CONTROL: DeviceNumber = DeviceNumber::new(10, 237);
const LOOP_MAJOR: u64 = 7;
const ATTACH_BACKOFF: Duration = Duration::from_millis(5);

const LO_FLAGS_READ_ONLY: u32 = 1;
const LO_FLAGS_AUTOCLEAR: u32 = 4;

mod ioctl {
    use super::LoopConfig;

    nix::ioctl_none_bad!(ctl_get_free, 0x4C82);
    nix::ioctl_write_ptr_bad!(configure, 0x4C0A, LoopConfig);
}

#[derive(SmartDefault)]
#[repr(C)]
struct LoopInfo64 {
    lo_device: u64,
    lo_inode: u64,
    lo_rdevice: u64,
    lo_offset: u64,
    lo_sizelimit: u64,
    lo_number: u32,
    lo_encrypt_type: u32,
    lo_encrypt_key_size: u32,
    lo_flags: u32,
    #[default([0; 64])]
    lo_file_name: [u8; 64],
    #[default([0; 64])]
    lo_crypt_name: [u8; 64],
    lo_encrypt_key: [u8; 32],
    lo_init: [u64; 2],
}

#[derive(Default)]
#[repr(C)]
struct LoopConfig {
    fd: u32,
    block_size: u32,
    info: LoopInfo64,
    reserved: [u64; 8],
}

const _: () = assert!(std::mem::size_of::<LoopInfo64>() == 232);
const _: () = assert!(std::mem::size_of::<LoopConfig>() == 304);

#[derive(Debug, ThisError)]
#[error("expected /dev/loopN: {0:?}")]
pub struct InvalidLoopDevNum(String);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display, From)]
#[display("{DEVICE_PREFIX}{_0}")]
pub struct LoopDevNum(u32);

impl LoopDevNum {
    pub fn get(self) -> u32 {
        self.0
    }

    pub fn path(self) -> Result<SafePathBuf<IsAbsolute, StrictComponents>, path::ValidationError> {
        PathBuf::from(self.to_string()).try_into()
    }
}

impl FromStr for LoopDevNum {
    type Err = InvalidLoopDevNum;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let invalid = || InvalidLoopDevNum(s.to_string());
        let digits = s.strip_prefix(DEVICE_PREFIX).ok_or_else(invalid)?;
        let canonical = digits == "0"
            || (digits.starts_with(|c: char| c.is_ascii_digit() && c != '0')
                && digits.bytes().all(|b| b.is_ascii_digit()));
        if !canonical {
            return Err(invalid());
        }
        digits.parse().map(Self).map_err(|_| invalid())
    }
}

#[derive(Debug, ThisError)]
pub enum OpenError {
    #[error("loop device path: {0}")]
    Path(#[from] path::ValidationError),
    #[error(transparent)]
    Open(#[from] file::ValidationError),
    #[error("{path:?} is device {device}, not the expected device")]
    WrongDevice { path: PathBuf, device: DeviceNumber },
}

#[derive(Debug, ThisError)]
pub enum AttachError {
    #[error("reopening backing file: {0}")]
    Backing(#[source] file::ValidationError),
    #[error("LOOP_CTL_GET_FREE: {0}")]
    GetFree(#[source] Errno),
    #[error("kernel returned invalid loop number {0}")]
    Number(i32),
    #[error("opening loop device: {0}")]
    Open(#[source] OpenError),
    #[error("LOOP_CONFIGURE: {0}")]
    Configure(#[source] Errno),
    #[error("no free loop device after {0:?}")]
    TimedOut(Duration),
}

pub struct LoopControl(SafeFile<IsCharDevice, Any, Any>);

impl LoopControl {
    pub fn open() -> Result<Self, OpenError> {
        let path: &SafePath<IsAbsolute, StrictComponents> = Path::new(CONTROL_PATH).try_into()?;
        let file: SafeFile<IsCharDevice, Any, Any> = SafeFile::open(path, OpenFlags::RDWR)?;
        let device = file.rdev()?;
        if device != LOOP_CONTROL {
            return Err(OpenError::WrongDevice {
                path: path.as_ref().to_path_buf(),
                device,
            });
        }
        Ok(Self(file))
    }

    pub fn attach<R, O>(
        &self,
        backing: &SafeFile<IsRegularFile, R, O>,
        access: Access,
        timeout: Duration,
    ) -> Result<LoopDevice, AttachError>
    where
        R: file::Ownership,
        O: file::Writability,
    {
        let deadline = Instant::now() + timeout;

        let (open_flags, lo_flags) = match access {
            Access::ReadOnly => (OpenFlags::RDONLY, LO_FLAGS_AUTOCLEAR | LO_FLAGS_READ_ONLY),
            Access::ReadWrite => (OpenFlags::RDWR, LO_FLAGS_AUTOCLEAR),
        };

        let backing = backing.reopen(open_flags).map_err(AttachError::Backing)?;
        let config = LoopConfig {
            fd: backing.as_raw_fd() as u32,
            info: LoopInfo64 {
                lo_flags,
                ..LoopInfo64::default()
            },
            ..LoopConfig::default()
        };

        loop {
            // SAFETY: LOOP_CTL_GET_FREE takes no argument.
            let raw =
                unsafe { ioctl::ctl_get_free(self.0.as_raw_fd()) }.map_err(AttachError::GetFree)?;
            let number = u32::try_from(raw).map_err(|_| AttachError::Number(raw))?;
            let device = LoopDevice::open(number.into()).map_err(AttachError::Open)?;
            // SAFETY: `config` is a fully initialised `struct loop_config`.
            match unsafe { ioctl::configure(device.file.as_raw_fd(), &config) } {
                Ok(_) => return Ok(device),
                Err(Errno::EBUSY) => {}
                Err(e) => return Err(AttachError::Configure(e)),
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(AttachError::TimedOut(timeout));
            }
            std::thread::sleep(ATTACH_BACKOFF.min(remaining));
        }
    }
}

pub struct LoopDevice {
    number: LoopDevNum,
    path: SafePathBuf<IsAbsolute, StrictComponents>,
    file: SafeFile<IsBlockDevice, Any, Any>,
}

impl LoopDevice {
    pub fn open(number: LoopDevNum) -> Result<Self, OpenError> {
        let path = number.path()?;
        let file: SafeFile<IsBlockDevice, Any, Any> = SafeFile::open(&path, OpenFlags::RDWR)?;
        let device = file.rdev()?;

        if device.major() != LOOP_MAJOR {
            return Err(OpenError::WrongDevice {
                path: path.as_ref().to_path_buf(),
                device,
            });
        }

        Ok(Self { number, path, file })
    }

    pub fn number(&self) -> LoopDevNum {
        self.number
    }

    pub fn path(&self) -> &SafePath<IsAbsolute, StrictComponents> {
        &self.path
    }
}
