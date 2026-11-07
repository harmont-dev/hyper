// SPDX-License-Identifier: MIT
//! Typesafer filesystem paths.

use derive_more::AsRef;
use ref_cast::{ref_cast_custom, RefCastCustom};
use std::borrow::Borrow;
use std::ffi::OsStr;
use std::marker::PhantomData;
use std::ops::Deref;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::str::FromStr;
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
    #[error("contains whitespace")]
    Whitespace,
    #[error("{0} bytes, longer than NAME_MAX ({NAME_MAX})")]
    TooLong(usize),
}

/// A path component that isn't `.`, nor `..`, and has no `/` or whitespace.
#[derive(PartialEq, Eq, PartialOrd, Ord, Hash, RefCastCustom, derive_more::Debug)]
#[debug("{:?}", self.as_os_str())]
#[repr(transparent)]
pub struct StrictComponent([u8]);

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Hash, derive_more::Debug)]
#[debug("{:?}", self.as_os_str())]
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
                b' ' | b'\t' | b'\n' | b'\x0b' | b'\x0c' | b'\r' => {
                    return Err(ComponentError::Whitespace)
                }
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
#[derive(Debug, Clone, PartialEq, Eq)]
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IsRelative;

/// Ensure there are no `.` nor `..` components.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StrictComponents;

impl Components for StrictComponents {
    fn check(path: &Path) -> Result<(), ValidationError> {
        // This implementation cannot use Path::components because it
        // normalizes path elements.
        Ok(check_strict_components(path.as_os_str().as_bytes())?)
    }
}

const fn check_strict_components(raw: &[u8]) -> Result<(), ComponentError> {
    let mut rest = match raw {
        [b'/'] => return Ok(()),
        [b'/', body @ ..] => body,
        _ => raw,
    };
    loop {
        let mut end = 0;
        while end < rest.len() && rest[end] != b'/' {
            end += 1;
        }
        let (segment, tail) = rest.split_at(end);
        if let Err(e) = StrictComponent::check(segment) {
            return Err(e);
        }
        match tail {
            [] => return Ok(()),
            [_, next @ ..] => rest = next,
        }
    }
}

const fn is_strict_absolute(raw: &[u8]) -> bool {
    matches!(raw, [b'/', ..]) && check_strict_components(raw).is_ok()
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
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SafePathBuf<A, S>(PathBuf, PhantomData<(A, S)>);

impl<A, S> SafePath<A, S> {
    #[ref_cast_custom]
    fn new_unchecked(path: &Path) -> &Self;

    pub fn as_path(&self) -> &Path {
        &self.path
    }
}

impl SafePath<IsAbsolute, StrictComponents> {
    pub fn from_static<const PATH: &'static str>() -> &'static Self {
        const {
            assert!(
                is_strict_absolute(PATH.as_bytes()),
                "not a strict absolute path"
            )
        };
        Self::new_unchecked(Path::new(PATH))
    }
}

impl<A> SafePath<A, StrictComponents> {
    /// Join a component to create a new [`SafePathBuf`].
    pub fn join(&self, name: &StrictComponent) -> SafePathBuf<A, StrictComponents> {
        SafePathBuf(self.path.join(name.as_path()), PhantomData)
    }

    /// Given `/b/x/y`, base `/b`, returns `x/y`.
    pub fn strip_base(
        &self,
        base: &SafePath<IsAbsolute, StrictComponents>,
    ) -> Result<&SafePath<IsRelative, StrictComponents>, RelativeError> {
        let rest = self
            .path
            .strip_prefix(base.as_path())
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

    pub fn file_name(&self) -> Option<&StrictComponent> {
        let raw = self.path.as_os_str().as_bytes();
        let name = raw.rsplit(|&b| b == b'/').next()?;
        (!name.is_empty()).then(|| StrictComponent::new_unchecked(name))
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

impl<A, S> Borrow<SafePath<A, S>> for SafePathBuf<A, S> {
    fn borrow(&self) -> &SafePath<A, S> {
        self
    }
}

impl<A, S> ToOwned for SafePath<A, S> {
    type Owned = SafePathBuf<A, S>;
    fn to_owned(&self) -> SafePathBuf<A, S> {
        SafePathBuf(self.path.to_path_buf(), PhantomData)
    }
}

impl<A, S> From<SafePathBuf<A, S>> for PathBuf {
    fn from(path: SafePathBuf<A, S>) -> Self {
        path.0
    }
}

impl<A, S> FromStr for SafePathBuf<A, S>
where
    A: Absoluteness,
    S: Components,
{
    type Err = ValidationError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        PathBuf::from(s).try_into()
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

#[cfg(test)]
mod tests {
    use super::{
        ComponentError, IsAbsolute, RelativeError, SafePath, SafePathBuf, StrictComponent,
        StrictComponents, ValidationError,
    };
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::assert_matches;
    use std::path::{Path, PathBuf};
    use test_strategy::proptest;

    // The fully-enforced flavor used at every real call site.
    type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

    fn strict(p: impl AsRef<Path>) -> Strict {
        p.as_ref().to_path_buf().try_into().unwrap()
    }

    // A plain, safe path component: no `.`/`..`/`/`/empty.
    fn safe_component() -> impl Strategy<Value = String> {
        "[a-z][a-z0-9_]{0,7}"
    }

    // A component that must make StrictComponents reject the whole path.
    fn loose_component() -> impl Strategy<Value = String> {
        prop_oneof![
            Just(".".to_string()),
            Just("..".to_string()),
            Just("".to_string())
        ]
    }

    fn join_abs(parts: &[String]) -> PathBuf {
        let mut p = PathBuf::from("/");
        for part in parts {
            p.push(part);
        }
        p
    }

    fn components(len: std::ops::Range<usize>) -> impl Strategy<Value = Vec<String>> {
        prop::collection::vec(safe_component(), len)
    }

    #[proptest]
    fn accepts_clean_absolute_paths(#[strategy(components(1..6))] parts: Vec<String>) {
        let path = join_abs(&parts);
        prop_assert!(Strict::try_from(path).is_ok());
    }

    #[proptest]
    fn rejects_any_loose_component(
        #[strategy(components(0..4))] prefix: Vec<String>,
        #[strategy(loose_component())] bad: String,
        #[strategy(components(0..4))] suffix: Vec<String>,
    ) {
        let mut parts = prefix;
        parts.push(bad);
        parts.extend(suffix);
        // Build the path from a RAW string, not via PathBuf::push: pushing an empty
        // component collapses it to a bare separator, hiding the `//` we want to
        // test. Raw joining makes `.`, `..`, and empty (`//`) literally present.
        let path = PathBuf::from(format!("/{}", parts.join("/")));
        prop_assume!(path != Path::new("/"));
        assert_matches!(Strict::try_from(path), Err(ValidationError::Component(_)));
    }

    #[proptest]
    fn rejects_whitespace_anywhere_in_any_component(
        #[strategy(components(0..4))] prefix: Vec<String>,
        #[strategy(safe_component())] head: String,
        #[strategy(safe_component())] tail: String,
        #[strategy(prop::sample::select(vec![' ', '\t', '\n', '\x0b', '\x0c', '\r']))] ws: char,
        #[strategy(0usize..3)] at: usize,
    ) {
        let bad = match at {
            0 => format!("{ws}{head}"),
            1 => format!("{head}{ws}{tail}"),
            _ => format!("{head}{ws}"),
        };
        let path = PathBuf::from(format!(
            "/{}",
            prefix
                .iter()
                .chain([&bad])
                .cloned()
                .collect::<Vec<_>>()
                .join("/")
        ));
        assert_matches!(
            Strict::try_from(path),
            Err(ValidationError::Component(ComponentError::Whitespace))
        );
    }

    #[proptest]
    fn rejects_relative_paths(#[strategy(components(1..6))] parts: Vec<String>) {
        let rel: PathBuf = parts.iter().collect();
        assert_matches!(Strict::try_from(rel), Err(ValidationError::NotAbsolute));
    }

    #[proptest]
    fn strip_base_segments_round_trip(
        #[strategy(components(1..4))] base_parts: Vec<String>,
        #[strategy(components(1..5))] rel_parts: Vec<String>,
    ) {
        let base = join_abs(&base_parts);
        let full_parts: Vec<String> = base_parts.iter().chain(rel_parts.iter()).cloned().collect();
        let full = join_abs(&full_parts);

        let safe = Strict::try_from(full.clone()).unwrap();
        let segments: Vec<String> = safe
            .strip_base(&strict(&base))
            .unwrap()
            .segments()
            .map(|s| s.as_os_str().to_string_lossy().into_owned())
            .collect();
        prop_assert_eq!(&segments, &rel_parts);

        let mut rebuilt = base.clone();
        rebuilt.extend(&segments);
        prop_assert_eq!(rebuilt, full);
    }

    #[proptest]
    fn strip_base_rejects_paths_outside_base(
        #[strategy(components(1..4))] base_parts: Vec<String>,
        #[strategy(components(1..4))] other_parts: Vec<String>,
    ) {
        // Force divergence at the first component so `other` cannot be under `base`.
        let base = join_abs(&base_parts);
        let mut other = vec!["zzdifferent".to_string()];
        other.extend(other_parts);
        let path = join_abs(&other);

        let safe = Strict::try_from(path).unwrap();
        assert_matches!(
            safe.strip_base(&strict(&base)),
            Err(RelativeError::NotUnderBase)
        );
    }

    #[proptest]
    fn file_name_returns_the_joined_component(
        #[strategy(components(0..5))] parts: Vec<String>,
        #[strategy(safe_component())] name: String,
    ) {
        let parent = Strict::try_from(join_abs(&parts)).unwrap();
        let name: &StrictComponent = name.as_str().try_into().unwrap();
        let joined = parent.join(name);
        prop_assert_eq!(joined.file_name(), Some(name));
    }

    #[proptest]
    fn file_name_of_a_relative_path_is_its_last_segment(
        #[strategy(components(1..4))] base_parts: Vec<String>,
        #[strategy(components(1..5))] rel_parts: Vec<String>,
    ) {
        let base = join_abs(&base_parts);
        let full_parts: Vec<String> = base_parts.iter().chain(rel_parts.iter()).cloned().collect();
        let safe = Strict::try_from(join_abs(&full_parts)).unwrap();
        let rel = safe.strip_base(&strict(&base)).unwrap();
        prop_assert_eq!(rel.file_name(), rel.segments().last());
    }

    #[proptest]
    fn strip_base_refuses_the_base_itself(#[strategy(components(1..4))] base_parts: Vec<String>) {
        let base = join_abs(&base_parts);
        let safe = Strict::try_from(base.clone()).unwrap();
        assert_matches!(
            safe.strip_base(&strict(&base)),
            Err(RelativeError::EqualsBase)
        );
    }

    #[rstest]
    fn root_has_no_file_name() {
        let root = SafePath::<IsAbsolute, StrictComponents>::from_static::<"/">();
        assert_eq!(root.file_name(), None);
    }
}
