use crate::fs::file::{self, Any, IsRegularFile, OpenFlags, SafeFile};
use crate::fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum BackingError {
    #[error("backing file {path}: {source}")]
    Canonicalize {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("backing file must be under {}: {}", .base.display(), .path.display())]
    OutsideBase { base: PathBuf, path: PathBuf },
    #[error("backing path: {0}")]
    Path(#[from] path::ValidationError),
    #[error("backing file: {0}")]
    Open(#[from] file::ValidationError),
}

#[derive(Debug, Clone)]
pub struct BackingFile(Arc<SafeFile<IsRegularFile, Any, Any>>);

impl BackingFile {
    pub fn open(path: &Path, base: &Path) -> Result<Self, BackingError> {
        let real = std::fs::canonicalize(path).map_err(|source| BackingError::Canonicalize {
            path: path.to_path_buf(),
            source,
        })?;
        if !real.starts_with(base) {
            return Err(BackingError::OutsideBase {
                base: base.to_path_buf(),
                path: real,
            });
        }
        let safe: &SafePath<IsAbsolute, StrictComponents> = real.as_path().try_into()?;
        let file = SafeFile::open(safe, OpenFlags::PATH)?;
        Ok(Self(Arc::new(file)))
    }

    pub fn file(&self) -> &SafeFile<IsRegularFile, Any, Any> {
        &self.0
    }
}
