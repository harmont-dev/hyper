use nix::libc::dev_t;
use nix::sys::stat::{major, makedev, minor};
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct DeviceNumber {
    major: u64,
    minor: u64,
}

impl DeviceNumber {
    pub const fn new(major: u64, minor: u64) -> Self {
        Self { major, minor }
    }

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

impl fmt::Display for DeviceNumber {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.major, self.minor)
    }
}
