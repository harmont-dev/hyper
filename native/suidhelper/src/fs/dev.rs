use super::file::DeviceType;
use derive_more::{Constructor, Display};
use nix::libc::dev_t;
use nix::sys::stat::{major, makedev, minor, Mode};
use std::marker::PhantomData;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Display, Constructor)]
#[display("{major}:{minor}")]
pub struct DeviceNumber {
    major: u64,
    minor: u64,
}

impl DeviceNumber {
    pub fn major(self) -> u64 {
        self.major
    }

    pub fn minor(self) -> u64 {
        self.minor
    }
}

impl From<dev_t> for DeviceNumber {
    fn from(rdev: dev_t) -> Self {
        Self::new(major(rdev), minor(rdev))
    }
}

impl From<DeviceNumber> for dev_t {
    fn from(dev: DeviceNumber) -> Self {
        makedev(dev.major, dev.minor)
    }
}

pub struct DeviceNode<T> {
    rdev: DeviceNumber,
    mode: Mode,
    kind: PhantomData<T>,
}

impl<T: DeviceType> DeviceNode<T> {
    pub const fn new(rdev: DeviceNumber, mode: Mode) -> Self {
        Self {
            rdev,
            mode,
            kind: PhantomData,
        }
    }

    pub fn rdev(&self) -> DeviceNumber {
        self.rdev
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }
}
