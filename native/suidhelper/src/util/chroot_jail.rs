pub enum Error {
    IoError(#[from] std::io::Error),
}

pub struct ChrootJail {
    /// The path to the chroot jail.
    path: PathBuf,
    /// The owning UID.
    uid: u32,
    /// The owning GID.
    gid: u32,
}

impl ChrootJail {
    /// Add a file into this `ChrootJail`.
    pub fn add_file(&self, source: &Path) -> Result<Self, Error> {
        let src_canon = std::fs::canonicalize(source)?;
    }

    /// Create this chroot jail and commit it to disk.
    pub fn to_disk(self) -> Result<(), Error>;
}
