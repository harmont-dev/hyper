// SPDX-License-Identifier: AGPL-3.0-only
//! Typestate-validated filesystem *names*.

use std::marker::PhantomData;
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
    #[error("path is not under its required base directory")]
    OutsideBase,
}

/// The universal "axis off" marker: implements every axis trait as a no-op.
pub struct Any;

/// Absoluteness axis: require an absolute path.
pub struct IsAbsolute;
/// Components axis: reject `.`, `..`, and empty components.
pub struct StrictComponents;

/// Confinement axis: require the path to live under `base`. Unlike the other
/// markers this one carries a *value* (the owned base), because the base is
/// runtime data - a path cannot be a type-level parameter. It is supplied to the
/// constructor (see [`SafePath::under`]) rather than picked purely by type.
pub struct LivesUnder(pub PathBuf);

/// Absoluteness axis.
pub trait Absoluteness {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

/// Components axis.
pub trait Components {
    fn check(path: &Path) -> Result<(), ValidationError>;
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

impl Confinement for LivesUnder {
    // Lexical prefix only - the cheap pre-filter. The authoritative, race-free
    // confinement proof is an O_NOFOLLOW walk from the base dirfd, which belongs
    // with the fd-based machinery, not here.
    fn check(&self, path: &Path) -> Result<(), ValidationError> {
        if path.starts_with(&self.0) {
            Ok(())
        } else {
            Err(ValidationError::OutsideBase)
        }
    }
}

/// A `PathBuf` proven to satisfy the lexical axes named by its type parameters.
pub struct SafePath<A, S, C>(PathBuf, PhantomData<(A, S, C)>);

impl<A, S, C> SafePath<A, S, C>
where
    A: Absoluteness,
    S: Components,
    C: Confinement,
{
    /// Validate `path` against every enforced axis, returning the first failure.
    /// `confine` carries the confinement axis's runtime base (use `Any` for none).
    fn validate(path: PathBuf, confine: C) -> Result<Self, ValidationError> {
        A::check(&path)?;
        S::check(&path)?;
        confine.check(&path)?;
        Ok(Self(path, PhantomData))
    }

    /// The validated path.
    pub fn as_path(&self) -> &Path {
        &self.0
    }
}

/// Confined constructor: validate `path` under `base` (the `LivesUnder` axis).
impl<A, S> SafePath<A, S, LivesUnder>
where
    A: Absoluteness,
    S: Components,
{
    pub fn under(path: PathBuf, base: PathBuf) -> Result<Self, ValidationError> {
        Self::validate(path, LivesUnder(base))
    }
}

impl<A, S, C> AsRef<Path> for SafePath<A, S, C> {
    fn as_ref(&self) -> &Path {
        &self.0
    }
}

/// Unconfined entry point: confinement is off (`Any`), so no base value is needed.
impl<A, S> TryFrom<PathBuf> for SafePath<A, S, Any>
where
    A: Absoluteness,
    S: Components,
{
    type Error = ValidationError;

    fn try_from(path: PathBuf) -> Result<Self, Self::Error> {
        Self::validate(path, Any)
    }
}
