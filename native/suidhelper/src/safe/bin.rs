use std::ffi::OsStr;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use thiserror::Error;

#[derive(Debug, Error)]
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

/// A validated tool-binary path.
///
/// [`SafeBin<NAME>`] is a [`PathBuf`] wrapper validating it is:
///
/// - An absolute path.
/// - Matches the compile-time `NAME`.
/// - Is not a symlink.
/// - Is owned by root.
/// - Is not writable.
///
/// This type guarantees that the binary under the specified path cannot be
/// spoofed by a malicious local user.
#[derive(Debug)]
pub struct SafeBin<const NAME: &'static str>(PathBuf);

impl<const NAME: &'static str> SafeBin<NAME> {
    /// Validate the given path is a safe binary.
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

impl<const NAME: &'static str> From<SafeBin<NAME>> for PathBuf {
    fn from(bin: SafeBin<NAME>) -> Self {
        bin.0
    }
}

impl<'a, const NAME: &'static str> From<&'a SafeBin<NAME>> for &'a Path {
    fn from(bin: &'a SafeBin<NAME>) -> Self {
        &bin.0
    }
}
