use derive_more::Display;
use hyperrs_fs::file::{self, Any, IsBlockDevice, OpenFlags, SafeFile};
use hyperrs_fs::path::{
    self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponentBuf, StrictComponents,
};
use std::ffi::OsStr;
use std::io;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

const DM_NAME_MAX: usize = 127;
pub(super) const MAPPER_PREFIX: &str = "/dev/mapper/";

#[derive(Debug, ThisError)]
#[error("invalid dm device name: {0:?}")]
pub struct InvalidDmName(String);

#[derive(Debug, ThisError)]
pub enum ParseDmDeviceError {
    #[error("expected a `{MAPPER_PREFIX}<name>` device: {0:?}")]
    NotMapper(String),
    #[error(transparent)]
    Name(#[from] InvalidDmName),
}

#[derive(Debug, ThisError)]
pub enum OpenDeviceError {
    #[error("resolving {path:?}: {source}")]
    Resolve {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error(transparent)]
    Path(#[from] path::ValidationError),
    #[error(transparent)]
    Open(#[from] file::ValidationError),
}

#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display("{}", _0.as_os_str().to_string_lossy())]
pub struct DmName(StrictComponentBuf);

impl DmName {
    pub fn from_device_path(path: impl AsRef<Path>) -> Result<Self, ParseDmDeviceError> {
        let path = path.as_ref();
        let not_mapper = || ParseDmDeviceError::NotMapper(path.display().to_string());
        let name = path
            .to_str()
            .and_then(|s| s.strip_prefix(MAPPER_PREFIX))
            .ok_or_else(not_mapper)?;

        Ok(name.parse()?)
    }

    /// The full path to the dm name.
    pub fn path(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        SafePath::from_static::<"/dev/mapper">().join(&self.0)
    }

    pub fn open(&self) -> Result<SafeFile<IsBlockDevice, Any, Any>, OpenDeviceError> {
        let link = self.path();
        let real =
            std::fs::canonicalize(link.as_path()).map_err(|source| OpenDeviceError::Resolve {
                path: link.as_path().to_path_buf(),
                source,
            })?;
        let real: SafePathBuf<IsAbsolute, StrictComponents> = real.try_into()?;
        Ok(SafeFile::open(&real, OpenFlags::PATH)?)
    }
}

impl FromStr for DmName {
    type Err = InvalidDmName;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let invalid = || InvalidDmName(s.to_string());

        fn is_valid(name: &str) -> bool {
            !name.is_empty()
                && name.len() <= DM_NAME_MAX
                && !name.starts_with('-')
                && !matches!(name, "." | ".." | "control")
                && name
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"#+-.:=@_".contains(&b))
        }

        if !is_valid(s) {
            return Err(invalid());
        }

        let component: &StrictComponent = s.try_into().map_err(|_| invalid())?;
        Ok(Self(component.to_owned()))
    }
}

impl AsRef<OsStr> for DmName {
    fn as_ref(&self) -> &OsStr {
        self.0.as_os_str()
    }
}

#[cfg(test)]
mod tests {
    use super::{DmName, ParseDmDeviceError};
    use proptest::prelude::*;
    use rstest::rstest;
    use std::path::Path;

    const DM_NAME_CHARS: &str =
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#+-.:=@_";

    fn dm_name() -> impl Strategy<Value = String> {
        "[0-9A-Za-z#+.:=@_][0-9A-Za-z#+.:=@_-]{0,126}".prop_filter("reserved", |s| {
            !matches!(s.as_str(), "." | ".." | "control")
        })
    }

    proptest! {
        #[test]
        fn round_trips_through_its_string_and_its_mapper_path(s in dm_name()) {
            let dm: DmName = s.parse().unwrap();
            prop_assert_eq!(dm.to_string(), s.clone());
            let path = dm.path();
            let expected = format!("/dev/mapper/{s}");
            prop_assert_eq!(path.as_path(), Path::new(&expected));
            prop_assert_eq!(DmName::from_device_path(path.as_path()).unwrap(), dm);
        }

        #[test]
        fn device_path_refuses_anything_outside_dev_mapper(s in dm_name(), dir in "/dev/[a-z]{0,8}/?|[a-z/]{0,12}") {
            prop_assume!(dir != "/dev/mapper/");
            let got = DmName::from_device_path(format!("{dir}{s}"));
            prop_assert!(matches!(got, Err(ParseDmDeviceError::NotMapper(_))), "{:?}", got);
        }

        #[test]
        fn rejects_any_byte_outside_the_charset(
            s in dm_name(),
            at in any::<prop::sample::Index>(),
            bad in any::<char>().prop_filter("charset", |c| !DM_NAME_CHARS.contains(*c)),
        ) {
            let mut chars: Vec<char> = s.chars().collect();
            chars.insert(at.index(chars.len() + 1), bad);
            let s: String = chars.into_iter().collect();
            prop_assert!(s.parse::<DmName>().is_err(), "accepted {:?}", s);
        }

        #[test]
        fn rejects_names_past_127_bytes(s in "[0-9A-Za-z]{128,200}") {
            prop_assert!(s.parse::<DmName>().is_err());
        }

        #[test]
        fn rejects_a_leading_dash(s in dm_name()) {
            let dashed = format!("-{s}");
            prop_assert!(dashed.parse::<DmName>().is_err());
        }
    }

    #[rstest]
    fn rejects_reserved_and_edge_names(
        #[values("", ".", "..", "control", "-", "--help", "a/b", "/x", "a\0b", "a b")] bad: &str,
    ) {
        assert!(bad.parse::<DmName>().is_err(), "accepted {bad:?}");
    }

    #[rstest]
    fn device_path_rejects_known_attack_strings(
        #[values(
            "/dev/sda",
            "/dev/loop0",
            "/dev/loop0/../sda",
            "/dev/mapper/x/../../sda",
            "/dev/mapper/x/",
            "/dev/mapper/control",
            "/dev/mapper/",
            "/dev/mapper",
            "../dev/mapper/x",
            "dev/mapper/x",
            "x"
        )]
        bad: &str,
    ) {
        assert!(DmName::from_device_path(bad).is_err(), "accepted {bad:?}");
    }
}
