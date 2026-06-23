// SPDX-License-Identifier: AGPL-3.0-only
//! Typestate-validated filesystem *names*.

use std::marker::PhantomData;
use std::path::{Component, Path, PathBuf};
use thiserror::Error as ThisError;

/// The single error type shared by every `SafePath` flavor. A given flavor only
/// ever yields the variants for the axes it actually enforces.
#[derive(Debug, Clone, Copy, ThisError)]
pub enum ValidationError {
    #[error("path is not absolute")]
    NotAbsolute,
    #[error("path contains `.`, `..`, or empty components")]
    LooseComponents,
    #[error("path is not under the required base directory")]
    NotUnderBase,
    #[error("path has no final component (equals the base)")]
    NoLeaf,
}

/// Absoluteness axis: require an absolute path.
#[derive(Debug)]
pub struct IsAbsolute;
/// Components axis: reject `.`, `..`, and empty components.
#[derive(Debug)]
pub struct StrictComponents;

/// Absoluteness axis.
pub trait Absoluteness {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

/// Components axis.
pub trait Components {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

impl Absoluteness for IsAbsolute {
    fn check(path: &Path) -> Result<(), ValidationError> {
        if path.is_absolute() {
            Ok(())
        } else {
            Err(ValidationError::NotAbsolute)
        }
    }
}

impl Components for StrictComponents {
    fn check(path: &Path) -> Result<(), ValidationError> {
        use std::os::unix::ffi::OsStrExt;

        // `Path::components()` keeps `..` (ParentDir) and any platform prefix but
        // silently normalizes `.` and empty (`//`) segments away -- so it alone
        // would accept `/a/./b` or `/a//b`. Use it to reject `..`/prefixes, then
        // scan the raw segments to reject `.` and empty components too, honoring
        // the no-`.`/`..`/empty guarantee this gate documents.
        if !path
            .components()
            .all(|c| matches!(c, Component::RootDir | Component::Normal(_)))
        {
            return Err(ValidationError::LooseComponents);
        }

        let bytes = path.as_os_str().as_bytes();
        let mut segments = bytes.split(|&b| b == b'/');
        // An absolute path's leading `/` yields one empty leading segment standing
        // for the root; that one is allowed. Every remaining segment must be a
        // plain name: non-empty (no `//` or trailing `/`) and not `.`/`..`.
        if path.is_absolute() {
            segments.next();
        }
        if segments.all(|s| !s.is_empty() && s != b"." && s != b"..") {
            Ok(())
        } else {
            Err(ValidationError::LooseComponents)
        }
    }
}

/// A `PathBuf` proven to satisfy the lexical axes named by its type parameters.
#[derive(Debug)]
pub struct SafePath<A, S>(PathBuf, PhantomData<(A, S)>);

impl<A> SafePath<A, StrictComponents> {
    /// Decompose the path, relative to `base`, into its parent components and
    /// final name - the input a directory walk consumes. Gated on
    /// `StrictComponents`, so there are no `.`/`..` to escape the split; every
    /// component is a plain name.
    ///
    /// Errs if the path is not under `base`, equals `base` (no final component),
    /// or contains a non-UTF-8 component.
    pub fn relative_to(&self, base: &Path) -> Result<(Vec<PathBuf>, PathBuf), ValidationError> {
        let rel = self
            .0
            .strip_prefix(base)
            .map_err(|_| ValidationError::NotUnderBase)?;

        let mut components = Vec::new();
        for component in rel.components() {
            match component {
                Component::Normal(s) => components.push(PathBuf::from(s)),
                // StrictComponents guarantees this is unreachable; reject anyway.
                _ => return Err(ValidationError::NotUnderBase),
            }
        }

        let leaf = components.pop().ok_or(ValidationError::NoLeaf)?;
        Ok((components, leaf))
    }
}

impl<A, S> AsRef<Path> for SafePath<A, S> {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

impl<A, S> TryFrom<PathBuf> for SafePath<A, S>
where
    A: Absoluteness,
    S: Components,
{
    type Error = ValidationError;

    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        A::check(&path)?;
        S::check(&path)?;
        Ok(Self(path, PhantomData))
    }
}
