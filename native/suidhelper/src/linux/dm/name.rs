use crate::fs::file::{self, Any, IsBlockDevice, OpenFlags, SafeFile};
use crate::fs::path::{
    self, IsAbsolute, SafePath, SafePathBuf, StrictComponent, StrictComponentBuf, StrictComponents,
};
use derive_more::Display;
use std::ffi::OsStr;
use std::io;
use std::path::PathBuf;
use std::str::FromStr;
use thiserror::Error as ThisError;

const DM_NAME_MAX: usize = 127;

#[derive(Debug, ThisError)]
#[error("invalid dm device name: {0:?}")]
pub struct InvalidDmName(String);

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

fn is_dm_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= DM_NAME_MAX
        && !name.starts_with('-')
        && !matches!(name, "." | ".." | "control")
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"#+-.:=@_".contains(&b))
}

impl DmName {
    pub fn as_os_str(&self) -> &OsStr {
        self.0.as_os_str()
    }

    pub fn path(&self) -> SafePathBuf<IsAbsolute, StrictComponents> {
        SafePath::from_static::<"/dev/mapper">().join(&self.0)
    }

    pub fn open(&self) -> Result<SafeFile<IsBlockDevice, Any, Any>, OpenDeviceError> {
        // The dm form is a symlink under `/dev/mapper` — a root-owned `0755` dir an
        // unprivileged caller cannot write — so resolving it to its real `/dev/dm-N`
        // node cannot be redirected by the caller. We must resolve first: `SafeFile`
        // refuses any symlink in the path (it must never follow an attacker-supplied
        // one) and would otherwise reject the dm symlink itself. The re-opened target
        // is still verified `IsBlockDevice`.
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
        if !is_dm_name(s) {
            return Err(invalid());
        }
        let component: &StrictComponent = s.try_into().map_err(|_| invalid())?;
        Ok(Self(component.to_owned()))
    }
}

impl AsRef<OsStr> for DmName {
    fn as_ref(&self) -> &OsStr {
        self.as_os_str()
    }
}

#[cfg(test)]
mod tests {
    use super::DmName;
    use proptest::prelude::*;
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
        fn round_trips_and_lives_under_dev_mapper(s in dm_name()) {
            let dm: DmName = s.parse().unwrap();
            prop_assert_eq!(dm.to_string(), s.clone());
            let expected = format!("/dev/mapper/{s}");
            let path = dm.path();
            prop_assert_eq!(path.as_path(), Path::new(&expected));
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

    #[test]
    fn rejects_reserved_and_edge_names() {
        for bad in [
            "", ".", "..", "control", "-", "--help", "a/b", "/x", "a\0b", "a b",
        ] {
            assert!(bad.parse::<DmName>().is_err(), "accepted {bad:?}");
        }
    }
}
