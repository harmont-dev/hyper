use crate::cli::dm::DmError;
use crate::cli::MapperPath;
use crate::cli::Op;
use crate::config::Config;
use crate::dm::{HyperDmName, HyperDmTable, NameError, TableError};
use hyperrs_fs::dev::OpenDeviceError;
use hyperrs_fs::file::{Any, IsBlockDevice, OpenFlags, SafeFile};
use hyperrs_linux::dm::thin_dump::{
    self as dump, DumpError, MappingsError, MetadataDump, ParseError, ThinMappings,
};
use hyperrs_linux::dm::{
    self, DevPath, DmTable, OpenThinError, Origin, Persistence, RemoveMode, RunError,
    SnapshotError, SnapshotTable, ThinId, ThinMessage, ThinPoolError,
};
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBinError;
use hyperrs_process::privilege::{PrivilegeError, Root, Unprivileged};
use nix::fcntl::{Flock, FlockArg};
use serde::Deserialize;
use serde::Serialize;
use serde_with::serde_as;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::num::NonZeroUsize;
use std::os::fd::AsFd;
use thiserror::Error as ThisError;

const SECTOR_BYTES: u64 = 512;
const CHUNK_BYTES: NonZeroUsize = NonZeroUsize::new(1 << 20).expect("2^20 is nonzero");

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinForkDelta {
    pool: HyperDmName,
    parent: HyperDmName,
    scratch_id: ThinId,
    #[serde_as(as = "MapperPath")]
    origin: HyperDmName,
    cow: DevPath,
    chunk_sectors: u64,
}

#[derive(Debug, ThisError)]
pub enum ForkDeltaError {
    #[error("opening the pool's metadata device: {0}")]
    Metadata(#[from] OpenDeviceError),
    #[error("locking metadata device: {0}")]
    Lock(#[source] io::Error),
    #[error(transparent)]
    Pool(#[from] ThinPoolError),
    #[error("reserving metadata snapshot: {0}")]
    Reserve(#[source] RunError),
    #[error("releasing metadata snapshot: {0}")]
    Release(#[source] RunError),
    #[error(transparent)]
    Dump(#[from] DumpError),
    #[error(transparent)]
    Parse(#[from] ParseError),
    #[error(transparent)]
    Mappings(#[from] MappingsError),
    #[error("copying ranges: {0}")]
    Copy(#[from] io::Error),
    #[error(transparent)]
    Bin(#[from] RootSafeBinError),
    #[error(transparent)]
    Privilege(#[from] PrivilegeError),
    #[error(transparent)]
    Source(#[from] OpenThinError),
    #[error(transparent)]
    Table(#[from] TableError),
    #[error(transparent)]
    Name(#[from] NameError),
    #[error(transparent)]
    Device(#[from] DmError),
    #[error("snapshotting the parent: {0}")]
    Snapshot(#[from] SnapshotError),
    #[error("activating the scratch snapshot: {0}")]
    Activate(#[source] RunError),
    #[error("destroying the scratch snapshot: {0}")]
    Destroy(#[source] RunError),
    #[error("removing the copy target: {0}")]
    Remove(#[source] RunError),
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct CopyStats {
    pub scanned_chunks: u64,
    pub written_chunks: u64,
}

impl Op for ThinForkDelta {
    type Output = CopyStats;
    type Error = ForkDeltaError;

    fn run(self, mut token: Unprivileged) -> Result<CopyStats, ForkDeltaError> {
        let config = Config::get();
        let dmsetup = dm::Dmsetup::new(config.dmsetup()?);
        let thin_dump = dump::ThinDump::new(config.thin_dump()?);
        let origin = Origin::Device((*self.origin).clone());
        let target = HyperDmTable::new(DmTable::Snapshot(SnapshotTable {
            sectors: 0,
            origin: origin.clone(),
            cow: self.cow.clone(),
            persistence: Persistence::Persistent,
            chunk: self.chunk_sectors,
        }))?;
        let scratch: HyperDmName = format!("hyper-scratch-{}", self.scratch_id).parse()?;

        let meta = {
            let root = token.elevate()?;
            let sectors = self.origin.sectors().map_err(DmError::from)?;
            let pool = dmsetup.thin_pool(&root, &self.pool)?;
            let meta = SafeFile::<IsBlockDevice, Any, Any>::open_block(
                pool.metadata(),
                OpenFlags::RDONLY,
            )?;
            let snapshot = match pool.open_thin(&self.parent)?.snapshot(self.scratch_id) {
                Ok(snapshot) => snapshot,
                Err(e @ SnapshotError::Resume { created: true, .. }) => {
                    let _ = pool.delete_thin(self.scratch_id);
                    return Err(e.into());
                }
                Err(e) => return Err(e.into()),
            };
            if let Err(e) = snapshot.activate(&scratch, sectors, Some(origin)) {
                let _ = pool.delete_thin(self.scratch_id);
                return Err(ForkDeltaError::Activate(e));
            }
            meta
        };

        let copied = self.copy_scratch(&scratch, target, &dmsetup, &thin_dump, &meta, &mut token);
        let destroyed = (|| {
            let root = token.elevate()?;
            dmsetup
                .thin_pool(&root, &self.pool)?
                .open_thin(&scratch)?
                .deactivate()
                .and_then(|thin| thin.delete())
                .map_err(ForkDeltaError::Destroy)
        })();
        let stats = copied?;
        destroyed?;
        Ok(stats)
    }
}

impl ThinForkDelta {
    fn copy_scratch(
        &self,
        scratch: &HyperDmName,
        target: HyperDmTable,
        dmsetup: &dm::Dmsetup,
        thin_dump: &dump::ThinDump,
        meta: &SafeFile<IsBlockDevice, Any, Any>,
        token: &mut Unprivileged,
    ) -> Result<CopyStats, ForkDeltaError> {
        let (id, dumped) = {
            let root = token.elevate()?;
            self.dump_reserved(&root, dmsetup, thin_dump, meta, scratch)?
        };
        let mappings = dumped.parse()?.mappings(id)?;

        let target_name: HyperDmName = format!("hyper-copy-{id}").parse()?;
        let mut src = {
            let _root = token.elevate()?;
            File::open(scratch.path().as_path())?
        };
        target.create(&target_name, Access::ReadWrite, token)?;
        let copied = (|| {
            let mut dst = {
                let _root = token.elevate()?;
                OpenOptions::new()
                    .write(true)
                    .open(target_name.path().as_path())?
            };
            let stats = copy_ranges(&mut src, &mut dst, &mappings, CHUNK_BYTES)?;
            dst.sync_all()?;
            Ok::<_, ForkDeltaError>(stats)
        })();
        let removed = (|| {
            let root = token.elevate()?;
            dmsetup
                .device(&root, &target_name)
                .remove(RemoveMode::Retry)
                .map_err(ForkDeltaError::Remove)
        })();
        let stats = copied?;
        removed?;
        Ok(stats)
    }

    fn dump_reserved(
        &self,
        root: &Root<'_>,
        dmsetup: &dm::Dmsetup,
        thin_dump: &dump::ThinDump,
        device: &SafeFile<IsBlockDevice, Any, Any>,
        src: &HyperDmName,
    ) -> Result<(ThinId, MetadataDump), ForkDeltaError> {
        let lock_fd = device
            .as_fd()
            .try_clone_to_owned()
            .map_err(ForkDeltaError::Lock)?;
        let _lock = Flock::lock(lock_fd, FlockArg::LockExclusive)
            .map_err(|(_, e)| ForkDeltaError::Lock(e.into()))?;
        let pool = dmsetup.thin_pool(root, &self.pool)?;
        let id = pool.open_thin(src)?.id();
        if pool.send(ThinMessage::ReserveMetadataSnap).is_err() {
            let _ = pool.send(ThinMessage::ReleaseMetadataSnap);
            pool.send(ThinMessage::ReserveMetadataSnap)
                .map_err(ForkDeltaError::Reserve)?;
        }
        let dumped = thin_dump.dump(root, device, id);
        let released = pool
            .send(ThinMessage::ReleaseMetadataSnap)
            .map_err(ForkDeltaError::Release);
        let dumped = dumped?;
        released?;
        Ok((id, dumped))
    }
}

pub fn copy_ranges(
    src: &mut (impl Read + Seek),
    dst: &mut (impl Write + Seek),
    mappings: &ThinMappings,
    chunk_bytes: NonZeroUsize,
) -> io::Result<CopyStats> {
    let overflow = || io::Error::new(io::ErrorKind::InvalidInput, "range offset overflows u64");
    let block_bytes = mappings
        .block_sectors
        .checked_mul(SECTOR_BYTES)
        .ok_or_else(overflow)?;
    let device_bytes = src.seek(SeekFrom::End(0))?;
    let spans = mappings
        .ranges
        .iter()
        .map(|range| {
            let start = range.begin.checked_mul(block_bytes).ok_or_else(overflow)?;
            let end = range
                .begin
                .checked_add(range.length)
                .and_then(|blocks| blocks.checked_mul(block_bytes))
                .ok_or_else(overflow)?;
            if end.saturating_sub(device_bytes) >= block_bytes {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!(
                        "blocks mapped up to byte {end} lie past the {device_bytes}-byte device"
                    ),
                ));
            }
            Ok((start.min(device_bytes), end.min(device_bytes)))
        })
        .collect::<io::Result<Vec<_>>>()?;

    let mut buf = vec![0u8; chunk_bytes.get()];
    let mut stats = CopyStats {
        scanned_chunks: 0,
        written_chunks: 0,
    };
    for (start, end) in spans {
        src.seek(SeekFrom::Start(start))?;
        dst.seek(SeekFrom::Start(start))?;
        let mut remaining = end - start;
        while remaining > 0 {
            let want = remaining.min(chunk_bytes.get() as u64) as usize;
            src.read_exact(&mut buf[..want])?;
            dst.write_all(&buf[..want])?;
            stats.scanned_chunks += 1;
            stats.written_chunks += 1;
            remaining -= want as u64;
        }
    }

    dst.flush()?;
    Ok(stats)
}

#[cfg(test)]
mod tests {
    use super::copy_ranges;
    use hyperrs_linux::dm::thin_dump::{BlockRange, ThinMappings};
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use proptest::sample::Index;
    use rstest::rstest;
    use std::io::{self, Cursor};
    use std::num::NonZeroUsize;
    use test_strategy::proptest;

    const SENTINEL: u8 = 0xAA;

    fn mappings(block_sectors: u64, ranges: &[(u64, u64)]) -> ThinMappings {
        ThinMappings {
            block_sectors,
            ranges: ranges
                .iter()
                .map(|&(begin, length)| BlockRange { begin, length })
                .collect(),
        }
    }

    fn chunk(bytes: usize) -> NonZeroUsize {
        NonZeroUsize::new(bytes).unwrap()
    }

    fn oracle(src: &[u8], mappings: &ThinMappings) -> Vec<u8> {
        let block_bytes = (mappings.block_sectors * 512) as usize;
        let mut expected = vec![SENTINEL; src.len()];
        for range in &mappings.ranges {
            let a = (range.begin as usize * block_bytes).min(src.len());
            let b = ((range.begin + range.length) as usize * block_bytes).min(src.len());
            expected[a..b].copy_from_slice(&src[a..b]);
        }
        expected
    }

    #[proptest]
    fn ranged_copy_writes_exactly_the_listed_ranges(
        #[strategy(proptest::collection::vec(any::<u8>(), 512..8192))] src: Vec<u8>,
        #[strategy(proptest::collection::vec((0usize..16, 1usize..4), 0..6))] cuts: Vec<(
            usize,
            usize,
        )>,
        #[strategy(prop_oneof![Just(1u64), Just(2u64)])] block_sectors: u64,
        #[strategy(64usize..600)] chunk_bytes: usize,
    ) {
        let block_bytes = (block_sectors * 512) as usize;
        let n_blocks = src.len() / block_bytes;
        prop_assume!(n_blocks > 0);

        let ranges: Vec<(u64, u64)> = cuts
            .iter()
            .map(|&(b, l)| {
                let begin = b % n_blocks;
                let length = l.min(n_blocks - begin).max(1);
                (begin as u64, length as u64)
            })
            .collect();
        let mappings = mappings(block_sectors, &ranges);
        let mut dst = Cursor::new(vec![SENTINEL; src.len()]);

        copy_ranges(
            &mut Cursor::new(&src),
            &mut dst,
            &mappings,
            chunk(chunk_bytes),
        )
        .unwrap();

        prop_assert_eq!(dst.into_inner(), oracle(&src, &mappings));
    }

    #[proptest]
    fn empty_ranges_write_nothing(
        #[strategy(proptest::collection::vec(any::<u8>(), 1..4096))] src: Vec<u8>,
        #[strategy(1usize..600)] chunk_bytes: usize,
    ) {
        let mut dst = Cursor::new(vec![SENTINEL; src.len()]);

        let stats = copy_ranges(
            &mut Cursor::new(&src),
            &mut dst,
            &mappings(1, &[]),
            chunk(chunk_bytes),
        )
        .unwrap();

        prop_assert_eq!(stats.written_chunks, 0);
        prop_assert_eq!(dst.into_inner(), vec![SENTINEL; src.len()]);
    }

    #[proptest]
    fn a_block_past_the_device_end_is_refused_before_any_write(
        #[strategy(1u64..=4)] block_sectors: u64,
        #[strategy(1u64..16)] device_blocks: u64,
        #[strategy(prop_oneof![Just(0u64), 1u64..512])] last_block_short: u64,
        #[strategy(0u64..4)] blocks_past: u64,
        #[strategy(1u64..4)] length: u64,
        #[strategy(proptest::collection::vec((0u64..16, 1u64..4), 0..4))] valid: Vec<(u64, u64)>,
        at: Index,
    ) {
        let device_bytes = device_blocks * block_sectors * 512 - last_block_short;
        let mut ranges: Vec<(u64, u64)> = valid
            .iter()
            .map(|&(b, l)| {
                let begin = b % device_blocks;
                (begin, l.min(device_blocks - begin))
            })
            .collect();
        ranges.insert(
            at.index(ranges.len() + 1),
            (device_blocks + blocks_past, length),
        );
        let mut dst = Cursor::new(vec![SENTINEL; device_bytes as usize]);

        let err = copy_ranges(
            &mut Cursor::new(vec![0u8; device_bytes as usize]),
            &mut dst,
            &mappings(block_sectors, &ranges),
            chunk(512),
        )
        .unwrap_err();

        prop_assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        prop_assert_eq!(dst.into_inner(), vec![SENTINEL; device_bytes as usize]);
    }

    #[rstest]
    #[case::one_chunk_per_range(1 << 20, &[(0, 3), (9, 1)], 2)]
    #[case::chunk_equal_to_a_block(512, &[(0, 3), (9, 1)], 4)]
    #[case::chunk_splitting_a_block(256, &[(0, 1)], 2)]
    #[case::uneven_tail(384, &[(0, 1)], 2)]
    fn chunk_accounting(
        #[case] chunk_bytes: usize,
        #[case] ranges: &[(u64, u64)],
        #[case] written_chunks: u64,
    ) {
        let src: Vec<u8> = (0..16 * 512).map(|i| (i % 251) as u8).collect();
        let mappings = mappings(1, ranges);
        let mut dst = Cursor::new(vec![SENTINEL; src.len()]);

        let stats = copy_ranges(
            &mut Cursor::new(&src),
            &mut dst,
            &mappings,
            chunk(chunk_bytes),
        )
        .unwrap();

        assert_eq!(stats.written_chunks, written_chunks);
        assert_eq!(stats.scanned_chunks, written_chunks);
        assert_eq!(dst.into_inner()[..src.len()], oracle(&src, &mappings)[..]);
    }

    #[rstest]
    #[case::block_size_overflows(u64::MAX, &[(0, 1)], io::ErrorKind::InvalidInput)]
    #[case::offset_overflows(1, &[(u64::MAX, 1)], io::ErrorKind::InvalidInput)]
    #[case::length_overflows(1, &[(0, u64::MAX)], io::ErrorKind::InvalidInput)]
    #[case::block_at_the_device_end(1, &[(1, 1)], io::ErrorKind::InvalidData)]
    #[case::range_running_past_the_end(1, &[(0, 2)], io::ErrorKind::InvalidData)]
    #[case::past_end_after_a_valid_range(1, &[(0, 1), (1, 1)], io::ErrorKind::InvalidData)]
    fn bad_geometry_is_refused_before_any_write(
        #[case] block_sectors: u64,
        #[case] ranges: &[(u64, u64)],
        #[case] kind: io::ErrorKind,
    ) {
        let mut dst = Cursor::new(vec![SENTINEL; 512]);

        let err = copy_ranges(
            &mut Cursor::new(vec![0u8; 512]),
            &mut dst,
            &mappings(block_sectors, ranges),
            chunk(512),
        )
        .unwrap_err();

        assert_eq!(err.kind(), kind);
        assert_eq!(dst.into_inner(), vec![SENTINEL; 512]);
    }
}
