// SPDX-License-Identifier: MIT
//! Typesafer filesystem paths.

use derive_more::AsRef;
use ref_cast::{ref_cast_custom, RefCastCustom};
use std::borrow::Borrow;
use std::ffi::OsStr;
use std::fmt;
use std::marker::PhantomData;
use std::ops::Deref;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

pub const NAME_MAX: usize = 255;

#[derive(Debug, ThisError)]
pub enum ValidationError {
    #[error("path is not absolute")]
    NotAbsolute,
    #[error("path component: {0}")]
    Component(#[from] ComponentError),
}

#[derive(Debug, ThisError)]
pub enum ComponentError {
    #[error("empty")]
    Empty,
    #[error("`.`")]
    CurrentDir,
    #[error("`..`")]
    ParentDir,
    #[error("contains `/`")]
    Separator,
    #[error("contains a NUL byte")]
    Nul,
    #[error("{0} bytes, longer than NAME_MAX ({NAME_MAX})")]
    TooLong(usize),
}

/// A path component that isn't `.`, nor `..`, nor `/`.
#[derive(PartialEq, Eq, PartialOrd, Ord, Hash, RefCastCustom)]
#[repr(transparent)]
pub struct StrictComponent([u8]);

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct StrictComponentBuf(Box<[u8]>);

impl StrictComponent {
    #[ref_cast_custom]
    const fn new_unchecked(bytes: &[u8]) -> &Self;

    const fn check(bytes: &[u8]) -> Result<(), ComponentError> {
        match bytes {
            [] => return Err(ComponentError::Empty),
            b"." => return Err(ComponentError::CurrentDir),
            b".." => return Err(ComponentError::ParentDir),
            _ => {}
        }
        if bytes.len() > NAME_MAX {
            return Err(ComponentError::TooLong(bytes.len()));
        }
        let mut i = 0;
        while i < bytes.len() {
            match bytes[i] {
                b'/' => return Err(ComponentError::Separator),
                0 => return Err(ComponentError::Nul),
                _ => i += 1,
            }
        }
        Ok(())
    }

    pub const fn from_static(name: &'static str) -> &'static Self {
        match Self::check(name.as_bytes()) {
            Ok(()) => Self::new_unchecked(name.as_bytes()),
            Err(_) => panic!("not a strict path component"),
        }
    }

    pub fn as_os_str(&self) -> &OsStr {
        OsStr::from_bytes(&self.0)
    }

    pub fn as_path(&self) -> &Path {
        Path::new(self.as_os_str())
    }
}

impl<'a> TryFrom<&'a OsStr> for &'a StrictComponent {
    type Error = ComponentError;
    fn try_from(name: &'a OsStr) -> Result<Self, Self::Error> {
        StrictComponent::check(name.as_bytes())?;
        Ok(StrictComponent::new_unchecked(name.as_bytes()))
    }
}

impl<'a> TryFrom<&'a str> for &'a StrictComponent {
    type Error = ComponentError;
    fn try_from(name: &'a str) -> Result<Self, Self::Error> {
        OsStr::new(name).try_into()
    }
}

impl AsRef<OsStr> for StrictComponent {
    fn as_ref(&self) -> &OsStr {
        self.as_os_str()
    }
}

impl AsRef<Path> for StrictComponent {
    fn as_ref(&self) -> &Path {
        self.as_path()
    }
}

impl fmt::Debug for StrictComponent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.as_os_str().fmt(f)
    }
}

impl ToOwned for StrictComponent {
    type Owned = StrictComponentBuf;
    fn to_owned(&self) -> StrictComponentBuf {
        StrictComponentBuf(self.0.into())
    }
}

impl Deref for StrictComponentBuf {
    type Target = StrictComponent;
    fn deref(&self) -> &StrictComponent {
        StrictComponent::new_unchecked(&self.0)
    }
}

impl Borrow<StrictComponent> for StrictComponentBuf {
    fn borrow(&self) -> &StrictComponent {
        self
    }
}

impl AsRef<Path> for StrictComponentBuf {
    fn as_ref(&self) -> &Path {
        self.as_path()
    }
}

impl fmt::Debug for StrictComponentBuf {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        (**self).fmt(f)
    }
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

impl Components for StrictComponents {
    fn check(path: &Path) -> Result<(), ValidationError> {
        // This implementation cannot use Path::components because it
        // normalizes path elements.
        let raw = path.as_os_str().as_bytes();
        if raw == b"/" {
            return Ok(());
        }
        let body = raw.strip_prefix(b"/").unwrap_or(raw);
        for segment in body.split(|&b| b == b'/') {
            StrictComponent::check(segment)?;
        }
        Ok(())
    }
}

/// A [`Path`] which satisfies [`Absoluteness`] and [`Components`]
/// constraints. The borrowed counterpart of [`SafePathBuf`].
#[derive(Debug, RefCastCustom, AsRef)]
#[repr(transparent)]
pub struct SafePath<A, S> {
    #[trivial]
    axes: PhantomData<(A, S)>,
    #[as_ref]
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

    pub fn split_last(&self) -> Option<(&SafePath<A, StrictComponents>, &StrictComponent)> {
        let raw = self.path.as_os_str().as_bytes();
        let slash = raw.iter().rposition(|&b| b == b'/')?;
        let name = &raw[slash + 1..];
        if name.is_empty() {
            return None;
        }
        let parent = &raw[..slash.max(1)];
        Some((
            SafePath::new_unchecked(Path::new(OsStr::from_bytes(parent))),
            StrictComponent::new_unchecked(name),
        ))
    }
}

impl SafePath<IsRelative, StrictComponents> {
    /// Given `foo/bar/baz`, returns `[foo, bar, baz]`.
    pub fn segments(&self) -> impl Iterator<Item = &StrictComponent> {
        self.path
            .as_os_str()
            .as_bytes()
            .split(|&b| b == b'/')
            .map(StrictComponent::new_unchecked)
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
