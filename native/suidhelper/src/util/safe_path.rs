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
}

/// The universal "axis off" marker: implements every axis trait as a no-op.
pub struct Any;

/// Absoluteness axis: require an absolute path.
pub struct IsAbsolute;
/// Components axis: reject `.`, `..`, and empty components.
pub struct StrictComponents;

/// Absoluteness axis.
pub trait Absoluteness {
    fn check(path: &Path) -> Result<(), ValidationError>;
}

/// Components axis.
pub trait Components {
    fn check(path: &Path) -> Result<(), ValidationError>;
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

/// A `PathBuf` proven to satisfy the lexical axes named by its type parameters.
pub struct SafePath<A, S>(PathBuf, PhantomData<(A, S)>);

impl<A, S> SafePath<A, S>
where
    A: Absoluteness,
    S: Components,
{
    /// The validated path.
    pub fn as_path(&self) -> &Path {
        &self.0
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
