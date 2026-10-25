// SPDX-License-Identifier: MIT
//! Typesafer filesystem paths.

use ref_cast::{ref_cast_custom, RefCastCustom};
use std::ffi::OsStr;
use std::marker::PhantomData;
use std::ops::Deref;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum ValidationError {
    #[error("path is not absolute")]
    NotAbsolute,
    #[error("path contains `.`, `..`, or empty components")]
    LooseComponents,
}

#[derive(Debug, ThisError)]
pub enum RelativeError {
    #[error("path is not under the required base directory")]
    NotUnderBase,
    #[error("path equals the base directory")]
    EqualsBase,
}

pub trait Absoluteness {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

pub trait Components {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

/// Ensure a path is absolute.
#[derive(Debug, Clone)]
pub struct IsAbsolute;

impl Absoluteness for IsAbsolute {
    fn check(path: &Path) -> Result<(), ValidationError> {
        if path.is_absolute() {
            Ok(())
        } else {
            Err(ValidationError::NotAbsolute)
        }
    }
}

/// A path known to be relative. Only produced by [`SafePath::strip_base`].
#[derive(Debug, Clone)]
pub struct IsRelative;

/// Ensure there are no `.` nor `..` components.
#[derive(Debug, Clone)]
pub struct StrictComponents;

#[cfg(unix)]
impl Components for StrictComponents {
    fn check(path: &Path) -> Result<(), ValidationError> {
        // This implementation cannot use Path::components because it
        // normalizes path elements.
        let raw = path.as_os_str().as_bytes();
        let body = raw.strip_prefix(b"/").unwrap_or(raw);

        let is_plain_name = |seg: &[u8]| !seg.is_empty() && seg != b"." && seg != b"..";
        if body.split(|&b| b == b'/').all(is_plain_name) {
            Ok(())
        } else {
            Err(ValidationError::LooseComponents)
        }
    }
}

/// A [`Path`] which satisfies [`Absoluteness`] and [`Components`]
/// constraints. The borrowed counterpart of [`SafePathBuf`].
#[derive(Debug, RefCastCustom)]
#[repr(transparent)]
pub struct SafePath<A, S> {
    #[trivial]
    axes: PhantomData<(A, S)>,
    path: Path,
}

/// An owned [`SafePath`].
#[derive(Debug, Clone)]
pub struct SafePathBuf<A, S>(PathBuf, PhantomData<(A, S)>);

impl<A, S> SafePath<A, S> {
    #[ref_cast_custom]
    fn new_unchecked(path: &Path) -> &Self;
}

impl<A> SafePath<A, StrictComponents> {
    /// Given `/b/x/y`, base `/b`, returns `x/y`.
    pub fn strip_base(
        &self,
        base: &Path,
    ) -> Result<&SafePath<IsRelative, StrictComponents>, RelativeError> {
        let rest = self
            .path
            .strip_prefix(base)
            .map_err(|_| RelativeError::NotUnderBase)?;
        if rest.as_os_str().is_empty() {
            return Err(RelativeError::EqualsBase);
        }
        // `strip_prefix` matches components, so re-check the remainder .
        StrictComponents::check(rest).map_err(|_| RelativeError::NotUnderBase)?;
        Ok(SafePath::new_unchecked(rest))
    }
}

impl SafePath<IsRelative, StrictComponents> {
    /// Given `foo/bar/baz`, returns `[foo, bar, baz]`.
    #[cfg(unix)]
    pub fn segments(&self) -> impl Iterator<Item = &OsStr> {
        self.path
            .as_os_str()
            .as_bytes()
            .split(|&b| b == b'/')
            .map(OsStr::from_bytes)
    }
}

impl<A, S> AsRef<Path> for SafePath<A, S> {
    fn as_ref(&self) -> &Path {
        &self.path
    }
}

impl<'a, A, S> TryFrom<&'a Path> for &'a SafePath<A, S>
where
    A: Absoluteness,
    S: Components,
{
    type Error = ValidationError;
    fn try_from(path: &'a Path) -> Result<Self, Self::Error> {
        A::check(path)?;
        S::check(path)?;
        Ok(SafePath::new_unchecked(path))
    }
}

impl<A, S> Deref for SafePathBuf<A, S> {
    type Target = SafePath<A, S>;
    fn deref(&self) -> &SafePath<A, S> {
        SafePath::new_unchecked(&self.0)
    }
}

impl<A, S> TryFrom<PathBuf> for SafePathBuf<A, S>
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
