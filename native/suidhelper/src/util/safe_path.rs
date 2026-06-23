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
    #[error("path component is not valid UTF-8")]
    NonUtf8,
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

impl<A> SafePath<A, StrictComponents> {
    /// Decompose the path, relative to `base`, into its parent components and
    /// final name - the input a directory walk consumes. Gated on
    /// `StrictComponents`, so there are no `.`/`..` to escape the split; every
    /// component is a plain name.
    ///
    /// Errs if the path is not under `base`, equals `base` (no final component),
    /// or contains a non-UTF-8 component.
    pub fn relative_to(&self, base: &Path) -> Result<(Vec<String>, String), ValidationError> {
        let rel = self
            .0
            .strip_prefix(base)
            .map_err(|_| ValidationError::NotUnderBase)?;

        let mut components = Vec::new();
        for component in rel.components() {
            match component {
                Component::Normal(s) => {
                    components.push(s.to_str().ok_or(ValidationError::NonUtf8)?.to_string())
                }
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
