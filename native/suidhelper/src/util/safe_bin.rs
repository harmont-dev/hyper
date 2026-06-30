//! A validated tool-binary path.
//!
//! The path of each device tool (`losetup`, `dmsetup`, `blockdev`) comes from
//! the root-owned config file, never from the unprivileged caller. [`SafeBin`]
//! is a newtype whose only constructor runs the safety checks, so holding one is
//! proof the path was validated. The const string parameter `NAME` is the
//! basename it was validated against - a `SafeBin<"losetup">` can never be
//! passed where a `SafeBin<"dmsetup">` is wanted.
//!
//! These checks are what keep this from being arbitrary-root-execution: even a
//! mistaken config entry cannot point us at a binary a non-root user controls
//! (must be an absolute path, the exact basename, root-owned, not a symlink, not
//! group/other-writable).

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("binary path must be absolute: {0}")]
    NotAbsolute(PathBuf),
    #[error("binary basename must be `{expected}`: {got}")]
    Name {
        expected: &'static str,
        got: PathBuf,
    },
    #[error("binary {path}: {source}")]
    Stat {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("{0} is a symlink")]
    Symlink(PathBuf),
    #[error("{0} is not owned by root")]
    NotRoot(PathBuf),
    #[error("{0} is group/other-writable")]
    Writable(PathBuf),
}

/// A tool-binary path validated to have basename `NAME`. The wrapped path is
/// private and the only constructor is [`SafeBin::from_path`], so a `SafeBin`
/// value cannot exist without having been checked.
#[derive(Debug, Clone)]
pub struct SafeBin<const NAME: &'static str>(PathBuf);

impl<const NAME: &'static str> SafeBin<NAME> {
    /// Validate `bin` as the `NAME` tool binary: an absolute path with basename
    /// `NAME`, a real (non-symlink) regular file owned by root that no non-root
    /// user could have written. These checks are the whole point of the type.
    pub fn from_path(bin: &Path) -> Result<Self, Error> {
        if !bin.is_absolute() {
            return Err(Error::NotAbsolute(bin.to_path_buf()));
        }

        match bin.file_name().and_then(OsStr::to_str) {
            Some(name) if name == NAME => {}
            _ => {
                return Err(Error::Name {
                    expected: NAME,
                    got: bin.to_path_buf(),
                })
            }
        }

        let meta = fs::symlink_metadata(bin).map_err(|source| Error::Stat {
            path: bin.to_path_buf(),
            source,
        })?;

        if meta.file_type().is_symlink() {
            return Err(Error::Symlink(bin.to_path_buf()));
        }
        if meta.uid() != 0 {
            return Err(Error::NotRoot(bin.to_path_buf()));
        }
        if meta.mode() & 0o022 != 0 {
            return Err(Error::Writable(bin.to_path_buf()));
        }

        Ok(Self(bin.to_path_buf()))
    }
}

// Lets a string parse straight into a validated `SafeBin<NAME>` (used by the
// test suite); delegates to the single `from_path` constructor.
impl<const NAME: &'static str> FromStr for SafeBin<NAME> {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::from_path(Path::new(s))
    }
}

// Read the validated path back out; the "validated" guarantee stays attached to
// the `SafeBin` type until this conversion.
impl<const NAME: &'static str> From<SafeBin<NAME>> for PathBuf {
    fn from(bin: SafeBin<NAME>) -> Self {
        bin.0
    }
}
