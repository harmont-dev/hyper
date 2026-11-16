use super::file::{self, Any, DeviceType, IsBlockDevice, OpenFlags, SafeFile};
use super::path::{self, IsAbsolute, SafePath, StrictComponents};
use derive_more::{Constructor, Display};
use nix::libc::dev_t;
use nix::sys::stat::{major, makedev, minor, Mode};
use std::fs;
use std::io;
use std::marker::PhantomData;
use std::path::{Path, PathBuf};
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

#[derive(Debug, ThisError)]
pub enum OpenDeviceError {
    #[error("reading {path}: {source}")]
    Sysfs {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("sysfs gives block device {dev} no DEVNAME")]
    NoName { dev: DeviceNumber },
    #[error("block device {dev}'s name {name:?}: {source}")]
    Name {
        dev: DeviceNumber,
        name: String,
        #[source]
        source: path::ValidationError,
    },
    #[error("opening block device {dev}: {source}")]
    Open {
        dev: DeviceNumber,
        #[source]
        source: file::ValidationError,
    },
    #[error("{} is block device {got}, not {want}", path.display())]
    Mismatch {
        path: PathBuf,
        want: DeviceNumber,
        got: DeviceNumber,
    },
}

impl SafeFile<IsBlockDevice, Any, Any> {
    /// Open block device `dev` at `/dev/<DEVNAME>`, the name the kernel gives it in sysfs.
    /// Whatever node sits at that path must be `dev` itself, or the open is refused.
    pub fn open_block(dev: DeviceNumber, flags: OpenFlags) -> Result<Self, OpenDeviceError> {
        let uevent = PathBuf::from(format!("/sys/dev/block/{dev}/uevent"));
        let text = fs::read_to_string(&uevent).map_err(|source| OpenDeviceError::Sysfs {
            path: uevent,
            source,
        })?;
        let name = dev_name(&text).ok_or(OpenDeviceError::NoName { dev })?;
        let node = Path::new("/dev").join(name);
        let safe = <&SafePath<IsAbsolute, StrictComponents>>::try_from(node.as_path()).map_err(
            |source| OpenDeviceError::Name {
                dev,
                name: name.to_owned(),
                source,
            },
        )?;
        open_numbered(safe, dev, flags)
    }
}

fn dev_name(uevent: &str) -> Option<&str> {
    uevent
        .lines()
        .find_map(|line| line.strip_prefix("DEVNAME="))
        .filter(|name| !name.is_empty())
}

fn open_numbered(
    node: &SafePath<IsAbsolute, StrictComponents>,
    want: DeviceNumber,
    flags: OpenFlags,
) -> Result<SafeFile<IsBlockDevice, Any, Any>, OpenDeviceError> {
    let open = |source| OpenDeviceError::Open { dev: want, source };
    let file = SafeFile::open(node, flags).map_err(open)?;
    let got = file.rdev().map_err(open)?;
    if got == want {
        Ok(file)
    } else {
        Err(OpenDeviceError::Mismatch {
            path: node.as_path().to_path_buf(),
            want,
            got,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{dev_name, open_numbered, DeviceNumber, OpenDeviceError};
    use crate::file::{Any, IsBlockDevice, OpenFlags, SafeFile};
    use crate::path::{IsAbsolute, SafePath, StrictComponents};
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use std::path::{Path, PathBuf};
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

    #[rstest]
    #[case::loop_device("MAJOR=7\nMINOR=3\nDEVNAME=loop3\nDEVTYPE=disk\n", Some("loop3"))]
    #[case::nested_name("MAJOR=104\nMINOR=0\nDEVNAME=cciss/c0d0\n", Some("cciss/c0d0"))]
    #[case::first_line("DEVNAME=dm-0\n", Some("dm-0"))]
    #[case::missing("MAJOR=7\nMINOR=3\n", None)]
    #[case::empty_name("DEVNAME=\n", None)]
    #[case::only_a_suffix_match("XDEVNAME=loop3\n", None)]
    fn dev_name_is_the_devname_line_of_the_uevent(
        #[case] uevent: &str,
        #[case] want: Option<&str>,
    ) {
        assert_eq!(dev_name(uevent), want);
    }

    /// Every block device the kernel lists, by number and by its `/dev` node.
    fn block_devices() -> Vec<(DeviceNumber, PathBuf)> {
        std::fs::read_dir("/sys/dev/block")
            .unwrap()
            .filter_map(|entry| {
                let entry = entry.unwrap();
                let dev = entry.file_name().to_str()?.parse().ok()?;
                let uevent = std::fs::read_to_string(entry.path().join("uevent")).ok()?;
                let node = Path::new("/dev").join(dev_name(&uevent)?);
                node.exists().then_some((dev, node))
            })
            .collect()
    }

    // O_PATH needs no read permission on the node, so this runs unprivileged.
    #[test]
    fn open_block_yields_the_device_it_was_asked_for() {
        let devices = block_devices();
        assert!(!devices.is_empty(), "no block devices in /sys/dev/block");
        for (dev, _) in devices {
            let file = SafeFile::<IsBlockDevice, Any, Any>::open_block(dev, OpenFlags::PATH)
                .unwrap_or_else(|e| panic!("{dev}: {e}"));
            assert_eq!(file.rdev().unwrap(), dev);
        }
    }

    #[test]
    fn a_node_that_is_another_device_is_refused() {
        let devices = block_devices();
        let [(_, node), (other, _), ..] = devices.as_slice() else {
            eprintln!(
                "SKIP a_node_that_is_another_device_is_refused: fewer than two block devices"
            );
            return;
        };
        let node = <&SafePath<IsAbsolute, StrictComponents>>::try_from(node.as_path()).unwrap();

        let got = open_numbered(node, *other, OpenFlags::PATH);

        assert!(
            matches!(got, Err(OpenDeviceError::Mismatch { want, .. }) if want == *other),
            "{got:?}"
        );
    }
}
