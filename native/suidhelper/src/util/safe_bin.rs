//! A validated `--bin` path.
//!
//! The caller names the binary to run, but it must be the expected tool and a
//! binary only root could have produced. [`SafeBin`] is a newtype whose only
//! constructor runs those checks, so holding one is proof the path was
//! validated. The const string parameter `NAME` is the basename it was validated
//! against - a `SafeBin<"losetup">` can never be passed where a
//! `SafeBin<"dmsetup">` is wanted. Combined with the [`FromStr`] impl (see
//! `tools`), clap validates the path at argument-parse time with no per-tool
//! boilerplate.
//!
//! These checks are what keep this from being arbitrary-root-execution: an
//! unprivileged caller cannot point us at a binary it controls (must be
//! root-owned, not group/other-writable, not a symlink, exact basename).

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("--bin must be an absolute path: {0}")]
    NotAbsolute(PathBuf),
    #[error("--bin basename must be `{expected}`: {got}")]
    Name {
        expected: &'static str,
        got: PathBuf,
    },
    #[error("--bin {path}: {source}")]
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

/// A `--bin` path validated to have basename `NAME`. The wrapped path is private
/// and the only constructor is the [`FromStr`] impl, so a `SafeBin` value cannot
/// exist without having been checked.
#[derive(Debug, Clone)]
pub struct SafeBin<const NAME: &'static str>(PathBuf);

// Lets clap validate `--bin` at parse time straight into a `SafeBin<NAME>`, with
// no per-tool value parser: the const basename is the whole spec. Validates that
// `s` is an absolute path with basename `NAME`, a regular root-owned file no
// non-root user could have written.
impl<const NAME: &'static str> FromStr for SafeBin<NAME> {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bin = Path::new(s);

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

// Read the validated path back out; the "validated" guarantee stays attached to
// the `SafeBin` type until this conversion.
impl<const NAME: &'static str> From<SafeBin<NAME>> for PathBuf {
    fn from(bin: SafeBin<NAME>) -> Self {
        bin.0
    }
}
