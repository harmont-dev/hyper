use hyperrs_fs::dev::DeviceNumber;
use nix::mount::{mount, MsFlags};
use nix::sys::statfs::{fstatfs, EXT4_SUPER_MAGIC};
use nix::sys::statvfs::fstatvfs;
use std::fs::{self, File};
use std::io;
use std::num::NonZeroU64;
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use thiserror::Error as ThisError;

const SECTOR_BYTES: u64 = 512;

mod ioctl {
    nix::ioctl_write_ptr!(resize_fs, b'f', 16, u64);
}

#[derive(Debug, ThisError)]
pub enum OpenError {
    #[error("opening {}: {source}", path.display())]
    Open {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("reading the filesystem at {}: {source}", path.display())]
    Statfs {
        path: PathBuf,
        #[source]
        source: nix::Error,
    },
    #[error("{} is not an ext4 mount", path.display())]
    NotExt4 { path: PathBuf },
}

#[derive(Debug, ThisError)]
pub enum GrowError {
    #[error("reading the filesystem: {0}")]
    Statfs(#[source] nix::Error),
    #[error("reading the mount's device number: {0}")]
    Device(#[source] io::Error),
    #[error("reading the size of block device {device}: {source}")]
    DeviceSize {
        device: DeviceNumber,
        #[source]
        source: io::Error,
    },
    #[error("block device {device} reports a size of {size:?}, not a sector count")]
    NotASectorCount { device: DeviceNumber, size: String },
    #[error("a filesystem block of {0} bytes is not a whole number of sectors")]
    BlockSize(u64),
    #[error("growing the filesystem to {blocks} blocks: {source}")]
    Resize {
        blocks: u64,
        #[source]
        source: nix::Error,
    },
}

#[derive(Debug)]
pub struct Ext4Mount {
    path: PathBuf,
    dir: File,
}

impl Ext4Mount {
    pub fn open(path: &Path) -> Result<Self, OpenError> {
        let dir = File::open(path).map_err(|source| OpenError::Open {
            path: path.to_path_buf(),
            source,
        })?;
        let fs = fstatfs(&dir).map_err(|source| OpenError::Statfs {
            path: path.to_path_buf(),
            source,
        })?;
        if fs.filesystem_type() != EXT4_SUPER_MAGIC {
            return Err(OpenError::NotExt4 {
                path: path.to_path_buf(),
            });
        }
        Ok(Self {
            path: path.to_path_buf(),
            dir,
        })
    }

    pub fn grow_to_device(&self) -> Result<u64, GrowError> {
        let block: u64 = fstatvfs(&self.dir).map_err(GrowError::Statfs)?.block_size();
        let sectors_per_block =
            NonZeroU64::new(block / SECTOR_BYTES).ok_or(GrowError::BlockSize(block))?;
        let device = DeviceNumber::from(self.dir.metadata().map_err(GrowError::Device)?.dev());
        let size = fs::read_to_string(format!("/sys/dev/block/{device}/size"))
            .map_err(|source| GrowError::DeviceSize { device, source })?;
        let sectors: u64 = size
            .trim()
            .parse()
            .map_err(|_| GrowError::NotASectorCount { device, size })?;
        let blocks = sectors / sectors_per_block;
        // SAFETY: EXT4_IOC_RESIZE_FS reads one u64, the new block count.
        unsafe { ioctl::resize_fs(self.dir.as_raw_fd(), &blocks) }
            .map_err(|source| GrowError::Resize { blocks, source })?;
        Ok(blocks)
    }

    pub fn skip_inode_table_init(&self) -> Result<(), nix::Error> {
        mount(
            None::<&str>,
            &self.path,
            None::<&str>,
            MsFlags::MS_REMOUNT,
            Some("noinit_itable"),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::{Ext4Mount, GrowError, OpenError};
    use crate::loopdev::{LoopControl, LoopDevice};
    use crate::Access;
    use assert_fs::TempDir;
    use hyperrs_fs::file::{Any, IsRegularFile, OpenFlags, SafeFile};
    use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
    use nix::mount::{mount, umount2, MntFlags, MsFlags};
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use std::assert_matches;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::time::Duration;

    const MIB: u64 = 1 << 20;
    const BLOCK: u64 = 4096;

    fn is_root() -> bool {
        nix::unistd::geteuid().is_root()
    }

    fn tool(name: &str) -> Option<PathBuf> {
        ["/usr/sbin", "/sbin", "/usr/bin"]
            .iter()
            .map(|dir| Path::new(dir).join(name))
            .find(|path| path.exists())
    }

    struct Mounted {
        _dir: TempDir,
        file: PathBuf,
        mnt: PathBuf,
        device: LoopDevice,
    }

    impl Mounted {
        fn new(fs_bytes: u64, device_bytes: u64) -> Option<Self> {
            let mke2fs = tool("mke2fs")?;
            let dir = TempDir::new().unwrap();
            let base = fs::canonicalize(dir.path()).unwrap();
            let file = base.join("disk.img");
            fs::File::create(&file)
                .unwrap()
                .set_len(device_bytes)
                .unwrap();
            let made = Command::new(mke2fs)
                .args(["-t", "ext4", "-F", "-q", "-b", &BLOCK.to_string()])
                .arg(&file)
                .arg(format!("{}k", fs_bytes / 1024))
                .status()
                .unwrap();
            assert!(made.success());
            let path: SafePathBuf<IsAbsolute, StrictComponents> = file.clone().try_into().unwrap();
            let backing =
                SafeFile::<IsRegularFile, Any, Any>::open(&path, OpenFlags::PATH).unwrap();
            let device = LoopControl::open()
                .unwrap()
                .attach(&backing, Access::ReadWrite, Duration::from_secs(2))
                .unwrap();
            let mnt = base.join("mnt");
            fs::create_dir(&mnt).unwrap();
            mount(
                Some(device.path().as_path()),
                &mnt,
                Some("ext4"),
                MsFlags::empty(),
                None::<&str>,
            )
            .unwrap();
            Some(Self {
                _dir: dir,
                file,
                mnt,
                device,
            })
        }

        fn block_count(&self) -> u64 {
            let out = Command::new(tool("dumpe2fs").unwrap())
                .arg("-h")
                .arg(self.device.path().as_path())
                .output()
                .unwrap();
            String::from_utf8_lossy(&out.stdout)
                .lines()
                .find_map(|line| line.strip_prefix("Block count:"))
                .unwrap()
                .trim()
                .parse()
                .unwrap()
        }

        fn mount_options(&self) -> String {
            fs::read_to_string("/proc/self/mountinfo")
                .unwrap()
                .lines()
                .find(|line| line.split(' ').nth(4) == Some(self.mnt.to_str().unwrap()))
                .unwrap()
                .to_string()
        }
    }

    impl Drop for Mounted {
        fn drop(&mut self) {
            let _ = umount2(&self.mnt, MntFlags::MNT_DETACH);
        }
    }

    macro_rules! mounted {
        ($fs:expr, $device:expr) => {
            match (is_root(), tool("dumpe2fs")) {
                (true, Some(_)) => match Mounted::new($fs, $device) {
                    Some(mounted) => mounted,
                    None => {
                        eprintln!("SKIP: needs mke2fs");
                        return;
                    }
                },
                _ => {
                    eprintln!("SKIP: needs root and e2fsprogs");
                    return;
                }
            }
        };
    }

    #[rstest]
    #[case::proc("/proc")]
    #[case::sysfs("/sys")]
    fn a_mount_that_is_not_ext4_is_refused(#[case] path: &str) {
        assert_matches!(
            Ext4Mount::open(Path::new(path)),
            Err(OpenError::NotExt4 { .. })
        );
    }

    #[rstest]
    #[case::already_filling_its_device(64 * MIB, 64 * MIB)]
    #[case::a_quarter_of_its_device(16 * MIB, 64 * MIB)]
    #[case::a_partial_last_block(16 * MIB, 64 * MIB + 512)]
    fn growing_fills_the_device_and_a_second_grow_changes_nothing_as_root(
        #[case] fs_bytes: u64,
        #[case] device_bytes: u64,
    ) {
        let disk = mounted!(fs_bytes, device_bytes);
        let fs = Ext4Mount::open(&disk.mnt).unwrap();

        assert_eq!(fs.grow_to_device().unwrap(), device_bytes / BLOCK);
        assert_eq!(disk.block_count(), device_bytes / BLOCK);
        assert_eq!(fs.grow_to_device().unwrap(), device_bytes / BLOCK);
        assert_eq!(disk.block_count(), device_bytes / BLOCK);
    }

    #[test]
    fn a_device_smaller_than_its_filesystem_is_an_error_and_never_shrinks_it_as_root() {
        let disk = mounted!(64 * MIB, 64 * MIB);
        fs::OpenOptions::new()
            .write(true)
            .open(&disk.file)
            .unwrap()
            .set_len(32 * MIB)
            .unwrap();
        let resized = Command::new(tool("losetup").unwrap())
            .arg("-c")
            .arg(disk.device.path().as_path())
            .status()
            .unwrap();
        assert!(resized.success());
        let fs = Ext4Mount::open(&disk.mnt).unwrap();

        assert_matches!(
            fs.grow_to_device(),
            Err(GrowError::Resize { blocks, .. }) if blocks == 32 * MIB / BLOCK
        );
        assert_eq!(disk.block_count(), 64 * MIB / BLOCK);
    }

    #[test]
    fn skipping_inode_table_init_remounts_with_noinit_itable_as_root() {
        let disk = mounted!(16 * MIB, 64 * MIB);
        let fs = Ext4Mount::open(&disk.mnt).unwrap();
        assert!(!disk.mount_options().contains("noinit_itable"));

        fs.skip_inode_table_init().unwrap();

        let options = disk.mount_options();
        assert!(options.contains("noinit_itable"), "{options}");
        assert!(options.contains(" rw,"), "{options}");
    }
}
