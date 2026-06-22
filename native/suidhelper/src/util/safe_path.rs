// SPDX-License-Identifier: AGPL-3.0-only
//! Typestate-validated filesystem paths.
//!
//! A [`SafePath`] is a `PathBuf` that has passed a set of checks chosen at the
//! *type* level. Each of the seven type parameters is an independent axis of
//! safety; the marker in each slot decides whether that axis is enforced. The
//! universal [`Any`] marker turns an axis off, so a fully-unchecked path is
//! `SafePath<Any, Any, Any, Any, Any, Any, Any>` and a specific flavor is a type
//! alias that fills in the markers it cares about.
//!
//! Six axes are pure type-level markers. The seventh, confinement
//! ([`LivesUnder`]), carries a runtime base value, so it is supplied to the
//! constructor ([`SafePath::under`]) rather than chosen purely by type - a
//! `&Path` cannot be a type parameter.
//!
//! Mechanism (option B): one trait per axis, implemented by the markers valid
//! for that axis (plus `Any`). The position of each parameter therefore enforces
//! at compile time that, e.g., slot `A` is an absoluteness choice and not an
//! ownership one. Validation runs every axis and reports the first failure as a
//! single shared [`ValidationError`]. There is no per-combination error type
//! (Rust cannot synthesise one from the type parameters), so every flavor
//! funnels through one enum and simply never produces the variants it does not
//! check.
//!
//! The state axes (existence, file type, owner, mode) need a `stat`; they share
//! one `symlink_metadata` call, taken only when at least one such axis is on.
//! NOTE: a `stat`-based check is time-of-check (see the TOCTOU discussion in the
//! tools); the race-proof, fd-bound operations live as methods elsewhere. This
//! type is the up-front gate, not the operation.

// Flavors are wired into the tools incrementally; drop once each is used.
#![allow(dead_code)]

use std::fs::Metadata;
use std::marker::PhantomData;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use thiserror::Error as ThisError;

/// The single error type shared by every `SafePath` flavor. A given flavor only
/// ever yields the variants for the axes it actually enforces.
#[derive(Debug, ThisError)]
pub enum ValidationError {
    #[error("path is not absolute")]
    NotAbsolute,
    #[error("path contains `.`, `..`, or empty components")]
    LooseComponents,
    #[error("file does not exist")]
    DoesNotExist,
    #[error("not a regular file")]
    NotRegularFile,
    #[error("not owned by root:root")]
    NotRootOwned,
    #[error("writable by group or other")]
    NonRootWritable,
    #[error("path is not under its required base directory")]
    OutsideBase,
    #[error("could not stat path: {0}")]
    Stat(#[source] std::io::Error),
}

/// The universal "axis off" marker: implements every axis trait as a no-op.
pub struct Any;

/// Absoluteness axis: require an absolute path.
pub struct IsAbsolute;
/// Components axis: reject `.`, `..`, and empty components.
pub struct StrictComponents;
/// Existence axis: require the path to exist.
pub struct MustExist;
/// File-type axis: require a regular file (a symlink does NOT qualify).
pub struct IsRegularFile;
/// Ownership axis: require `root:root` (uid 0, gid 0).
pub struct RootOwner;
/// Mode axis: require the file not be writable by group or other.
pub struct OnlyRootWritable;

/// Confinement axis: require the path to live under `base`. Unlike the other
/// markers this one carries a *value* (the base), because the base is runtime
/// data - a `&Path` cannot be a type-level parameter, only its lifetime can. So
/// it is supplied to the constructor (see [`SafePath::under`]) rather than picked
/// purely by type.
pub struct LivesUnder<'a>(pub &'a Path);

/// Absoluteness axis.
pub trait Absoluteness {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

/// Components axis.
pub trait Components {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

/// Existence axis.
pub trait Existence {
    const NEEDS_META: bool;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError>;
}

/// File-type axis.
pub trait FileType {
    const NEEDS_META: bool;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError>;
}

/// Ownership axis.
pub trait Ownership {
    const NEEDS_META: bool;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError>;
}

/// Mode/writability axis.
pub trait Writability {
    const NEEDS_META: bool;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError>;
}

/// Confinement axis. `&self` because the marker carries the base value.
pub trait Confinement {
    fn check(&self, path: &Path) -> Result<(), ValidationError>;
}

impl Absoluteness for Any {
    fn check(_: &Path) -> Result<(), ValidationError> {
        Ok(())
    }
}
impl Components for Any {
    fn check(_: &Path) -> Result<(), ValidationError> {
        Ok(())
    }
}
impl Existence for Any {
    const NEEDS_META: bool = false;
    fn check(_: Option<&Metadata>) -> Result<(), ValidationError> {
        Ok(())
    }
}
impl FileType for Any {
    const NEEDS_META: bool = false;
    fn check(_: Option<&Metadata>) -> Result<(), ValidationError> {
        Ok(())
    }
}
impl Ownership for Any {
    const NEEDS_META: bool = false;
    fn check(_: Option<&Metadata>) -> Result<(), ValidationError> {
        Ok(())
    }
}
impl Writability for Any {
    const NEEDS_META: bool = false;
    fn check(_: Option<&Metadata>) -> Result<(), ValidationError> {
        Ok(())
    }
}
impl Confinement for Any {
    fn check(&self, _: &Path) -> Result<(), ValidationError> {
        Ok(())
    }
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
        // Only a leading root and plain names; `.`/`..`/prefix are rejected.
        let ok = path
            .components()
            .all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
        if ok {
            Ok(())
        } else {
            Err(ValidationError::LooseComponents)
        }
    }
}

impl Existence for MustExist {
    const NEEDS_META: bool = true;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError> {
        meta.map(|_| ()).ok_or(ValidationError::DoesNotExist)
    }
}

impl FileType for IsRegularFile {
    const NEEDS_META: bool = true;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError> {
        match meta {
            None => Err(ValidationError::DoesNotExist),
            // `symlink_metadata` is an lstat, so a symlink reports as non-file.
            Some(m) if m.is_file() => Ok(()),
            Some(_) => Err(ValidationError::NotRegularFile),
        }
    }
}

impl Ownership for RootOwner {
    const NEEDS_META: bool = true;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError> {
        match meta {
            None => Err(ValidationError::DoesNotExist),
            Some(m) if m.uid() == 0 && m.gid() == 0 => Ok(()),
            Some(_) => Err(ValidationError::NotRootOwned),
        }
    }
}

impl Writability for OnlyRootWritable {
    const NEEDS_META: bool = true;
    fn check(meta: Option<&Metadata>) -> Result<(), ValidationError> {
        match meta {
            None => Err(ValidationError::DoesNotExist),
            Some(m) if m.mode() & 0o022 == 0 => Ok(()),
            Some(_) => Err(ValidationError::NonRootWritable),
        }
    }
}

impl Confinement for LivesUnder<'_> {
    // Lexical prefix only. For a may-not-exist leaf this is the cheap first gate;
    // the race-proof boundary is the O_NOFOLLOW parent walk (a method), and for a
    // must-exist path, combine with canonicalisation before trusting the prefix.
    fn check(&self, path: &Path) -> Result<(), ValidationError> {
        if path.starts_with(self.0) {
            Ok(())
        } else {
            Err(ValidationError::OutsideBase)
        }
    }
}

/// A `PathBuf` proven to satisfy the seven axes named by its type parameters.
pub struct SafePath<A, S, M, I, R, O, C>(PathBuf, PhantomData<(A, S, M, I, R, O, C)>);

impl<A, S, M, I, R, O, C> SafePath<A, S, M, I, R, O, C>
where
    A: Absoluteness,
    S: Components,
    M: Existence,
    I: FileType,
    R: Ownership,
    O: Writability,
    C: Confinement,
{
    /// Validate `path` against every enforced axis, returning the first failure.
    /// `confine` carries the confinement axis's runtime base (use `Any` for none).
    fn validate(path: PathBuf, confine: C) -> Result<Self, ValidationError> {
        // Lexical axes first - cheap, no syscall.
        A::check(&path)?;
        S::check(&path)?;
        confine.check(&path)?;

        // One `stat` iff a state axis is enforced. `lstat`, so a symlinked leaf
        // is judged as a symlink (and rejected by IsRegularFile).
        let needs_meta = M::NEEDS_META || I::NEEDS_META || R::NEEDS_META || O::NEEDS_META;
        let meta = if needs_meta {
            match std::fs::symlink_metadata(&path) {
                Ok(m) => Some(m),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
                Err(e) => return Err(ValidationError::Stat(e)),
            }
        } else {
            None
        };

        M::check(meta.as_ref())?;
        I::check(meta.as_ref())?;
        R::check(meta.as_ref())?;
        O::check(meta.as_ref())?;

        Ok(Self(path, PhantomData))
    }
}

/// Confined constructor: validate `path` under `base` (the `LivesUnder` axis).
impl<'a, A, S, M, I, R, O> SafePath<A, S, M, I, R, O, LivesUnder<'a>>
where
    A: Absoluteness,
    S: Components,
    M: Existence,
    I: FileType,
    R: Ownership,
    O: Writability,
{
    pub fn under(path: PathBuf, base: &'a Path) -> Result<Self, ValidationError> {
        Self::validate(path, LivesUnder(base))
    }
}

impl<A, S, M, I, R, O, C> AsRef<Path> for SafePath<A, S, M, I, R, O, C> {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

/// Unconfined entry point: every axis but confinement is type-selected, and
/// confinement is off (`Any`), so no base value is needed.
impl<A, S, M, I, R, O> TryFrom<PathBuf> for SafePath<A, S, M, I, R, O, Any>
where
    A: Absoluteness,
    S: Components,
    M: Existence,
    I: FileType,
    R: Ownership,
    O: Writability,
{
    type Error = ValidationError;

    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        Self::validate(path, Any)
    }
}
