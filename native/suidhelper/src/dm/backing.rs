// TODO(markovejnovic): This is a little bit slop and should ideally be removed/cleaned up.
use super::name::{HyperDmName, NameError};
use crate::config::Config;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{self, Any, IsRegularFile, OpenFlags, SafeFile};
use hyperrs_fs::path::{IsAbsolute, SafePath, StrictComponents};
use hyperrs_linux::dm::{DevPath, DmTable, Role};
use hyperrs_linux::loopdev::{self, LoopBacking};
use hyperrs_linux::Access;
use nix::sys::stat::Mode;
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum BackingError {
    #[error("backing file must be under {}: {}", .base.display(), .path.display())]
    OutsideBase { base: PathBuf, path: PathBuf },
    #[error("backing file: {0}")]
    Open(#[from] file::ValidationError),
}

#[derive(Debug, Clone)]
pub struct BackingFile(Arc<SafeFile<IsRegularFile, Any, Any>>);

impl BackingFile {
    pub fn open(
        path: &SafePath<IsAbsolute, StrictComponents>,
        base: &SafePath<IsAbsolute, StrictComponents>,
    ) -> Result<Self, BackingError> {
        let rel = path
            .strip_base(base)
            .map_err(|_| BackingError::OutsideBase {
                base: base.as_path().to_path_buf(),
                path: path.as_path().to_path_buf(),
            })?;
        let dir: SafeDir = SafeFile::open(base, OpenFlags::PATH)?;
        let file = dir.openat(rel.as_path(), OpenFlags::PATH, Mode::empty())?;
        Ok(Self(Arc::new(file)))
    }

    pub fn file(&self) -> &SafeFile<IsRegularFile, Any, Any> {
        &self.0
    }
}

#[derive(Debug, ThisError)]
pub enum TableError {
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
    pub fn new(table: DmTable) -> Result<Self, TableError> {
        HyperDmName::check_table(&table)?;
        let base = Config::get().hyper_base();
        let backing = table
            .paths()
            .map(|(role, path)| Ok((role, BackingFile::open(path, base)?)))
            .collect::<Result<_, BackingError>>()?;
        Ok(Self { table, backing })
    }

    pub fn table(&self) -> &DmTable {
        &self.table
    }

    pub fn backing(&self, role: Role) -> Option<&BackingFile> {
        self.backing.get(&role)
    }

    pub fn open_loop_backings(
        &self,
        access: impl Fn(Role) -> Access,
    ) -> Result<BTreeMap<Role, LoopBacking>, loopdev::BackingError> {
        self.backing
            .iter()
            .map(|(&role, backing)| Ok((role, LoopBacking::open(backing.file(), access(role))?)))
            .collect()
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
