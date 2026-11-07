use super::name::{HyperDmName, NameError};
use crate::config::Config;
use hyperrs_fs::file::{self, Any, IsRegularFile, OpenFlags, SafeFile};
use hyperrs_fs::path::{self, IsAbsolute, SafePath, StrictComponents};
use hyperrs_linux::dm::{DevPath, DmTable, ParseTableError, Role};
use std::collections::BTreeMap;
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
    pub fn open(
        path: &Path,
        base: &SafePath<IsAbsolute, StrictComponents>,
    ) -> Result<Self, BackingError> {
        let real = std::fs::canonicalize(path).map_err(|source| BackingError::Canonicalize {
            path: path.to_path_buf(),
            source,
        })?;
        if !real.starts_with(base.as_path()) {
            return Err(BackingError::OutsideBase {
                base: base.as_path().to_path_buf(),
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

#[derive(Debug, ThisError)]
pub enum TableError {
    #[error(transparent)]
    Parse(#[from] ParseTableError),
    #[error(transparent)]
    Name(#[from] NameError),
    #[error(transparent)]
    Backing(#[from] BackingError),
}

#[derive(Debug, Clone)]
pub struct HyperDmTable {
    table: DmTable,
    backing: BTreeMap<Role, BackingFile>,
}

impl HyperDmTable {
    pub fn resolve(s: &str) -> Result<Self, TableError> {
        let table: DmTable = s.parse()?;
        HyperDmName::check_table(&table)?;
        let base = Config::get().hyper_base();
        let backing = table
            .paths()
            .map(|(role, path)| Ok((role, BackingFile::open(path.as_path(), base)?)))
            .collect::<Result<_, BackingError>>()?;
        Ok(Self { table, backing })
    }

    pub fn attach<E>(
        &self,
        mut f: impl FnMut(Role, &BackingFile) -> Result<DevPath, E>,
    ) -> Result<DmTable, E> {
        let mut table = self.table.clone();
        for (role, path) in table.paths_mut() {
            *path = f(role, &self.backing[&role])?;
        }
        Ok(table)
    }
}
