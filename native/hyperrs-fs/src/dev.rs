use super::file::DeviceType;
use derive_more::{Constructor, Display};
use nix::libc::dev_t;
use nix::sys::stat::{major, makedev, minor, Mode};
use std::marker::PhantomData;
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
#[error("expected a `major:minor` device number: {0:?}")]
pub struct ParseDeviceNumberError(String);

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

impl FromStr for DeviceNumber {
    type Err = ParseDeviceNumberError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let invalid = || ParseDeviceNumberError(s.to_owned());
        let (major, minor) = s.split_once(':').ok_or_else(invalid)?;
        let digits = |part: &str| {
            part.bytes()
                .all(|b| b.is_ascii_digit())
                .then(|| part.parse().ok())
                .flatten()
                .ok_or_else(invalid)
        };
        Ok(Self::new(digits(major)?, digits(minor)?))
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

#[cfg(test)]
mod tests {
    use super::DeviceNumber;
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use test_strategy::proptest;

    #[proptest]
    fn display_round_trips_through_from_str(major: u64, minor: u64) {
        let dev = DeviceNumber::new(major, minor);
        assert_eq!(dev.to_string().parse::<DeviceNumber>().unwrap(), dev);
    }

    #[rstest]
    #[case::empty("")]
    #[case::no_colon("253")]
    #[case::empty_major(":1")]
    #[case::empty_minor("253:")]
    #[case::signed("+253:1")]
    #[case::padded(" 253:1")]
    #[case::trailing_newline("253:1\n")]
    #[case::three_parts("253:1:0")]
    #[case::overflow("18446744073709551616:0")]
    fn from_str_refuses_anything_but_major_colon_minor(#[case] raw: &str) {
        assert!(raw.parse::<DeviceNumber>().is_err(), "{raw:?}");
    }
}
