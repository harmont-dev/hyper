use crate::cli::MapperPath;
use crate::cli::OpError;
use crate::cli::ThinIdNumber;
use crate::config::Config;
use crate::dm::HyperDmName;
use hyperrs_fs::file::{self, Any, IsBlockDevice, OpenFlags, SafeFile};
use hyperrs_fs::path;
use hyperrs_linux::dm::thin_dump::{
    self as dump, DumpError, MappingsError, MetadataDump, ParseError, ThinMappings,
};
use hyperrs_linux::dm::{self, RunError, ThinId, ThinMessage, ThinPool, ThinPoolError};
use hyperrs_linux::loopdev::LoopDevNum;
use hyperrs_process::binary::RootSafeBinError;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use nix::fcntl::{Flock, FlockArg};
use serde::Deserialize;
use serde::Serialize;
use serde_with::{serde_as, DisplayFromStr};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::AsFd;
use thiserror::Error as ThisError;

const SECTOR_BYTES: u64 = 512;
const CHUNK_BYTES: usize = 1 << 20;

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ThinCopyArgs {
    #[serde_as(as = "DisplayFromStr")]
    pool: HyperDmName,
    #[serde_as(as = "DisplayFromStr")]
    meta: LoopDevNum,
    #[serde_as(as = "ThinIdNumber")]
    thin_id: ThinId,
    #[serde_as(as = "MapperPath")]
    src: HyperDmName,
    #[serde_as(as = "MapperPath")]
    dst: HyperDmName,
}

#[derive(Debug, ThisError)]
pub enum ThinCopyError {
    #[error("metadata device path: {0}")]
    Path(#[from] path::ValidationError),
    #[error("opening metadata device: {0}")]
    Open(#[from] file::ValidationError),
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
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct CopyStats {
    pub scanned_chunks: u64,
    pub written_chunks: u64,
}

pub fn run(args: ThinCopyArgs, token: &mut Unprivileged) -> Result<CopyStats, ThinCopyError> {
    let config = Config::get();
    let dmsetup = dm::Dmsetup::new(config.dmsetup()?);
    let thin_dump = dump::ThinDump::new(config.thin_dump()?);
    let meta = args.meta.path()?;

    let dumped = {
        let _root = token.elevate()?;
        dump_reserved(&dmsetup, &thin_dump, &args.pool, &meta, args.thin_id)?
    };
    let mappings = dumped.parse()?.mappings(args.thin_id)?;

    let (mut src, mut dst) = {
        let _root = token.elevate()?;
        let src = File::open(args.src.path().as_path())?;
        let dst = OpenOptions::new()
            .write(true)
            .open(args.dst.path().as_path())?;
        (src, dst)
    };
    Ok(copy_ranges(&mut src, &mut dst, &mappings, CHUNK_BYTES)?)
}

fn dump_reserved(
    dmsetup: &dm::Dmsetup,
    thin_dump: &dump::ThinDump,
    pool: &HyperDmName,
    meta: &path::SafePath<path::IsAbsolute, path::StrictComponents>,
    id: ThinId,
) -> Result<MetadataDump, ThinCopyError> {
    let device = SafeFile::<IsBlockDevice, Any, Any>::open(meta, OpenFlags::RDONLY)?;
    let lock_fd = device
        .as_fd()
        .try_clone_to_owned()
        .map_err(ThinCopyError::Lock)?;
    let _lock = Flock::lock(lock_fd, FlockArg::LockExclusive)
        .map_err(|(_, e)| ThinCopyError::Lock(e.into()))?;
    let pool = dmsetup.thin_pool(pool)?;
    reserve(&pool)?;
    let dumped = thin_dump.dump(&device, id);
    let released = pool
        .send(ThinMessage::ReleaseMetadataSnap)
        .map_err(ThinCopyError::Release);
    let dumped = dumped?;
    released?;
    Ok(dumped)
}

fn reserve(pool: &ThinPool<'_>) -> Result<(), ThinCopyError> {
    if pool.send(ThinMessage::ReserveMetadataSnap).is_ok() {
        return Ok(());
    }
    let _ = pool.send(ThinMessage::ReleaseMetadataSnap);
    pool.send(ThinMessage::ReserveMetadataSnap)
        .map_err(ThinCopyError::Reserve)
}

pub fn copy_ranges(
    src: &mut (impl Read + Seek),
    dst: &mut (impl Write + Seek),
    mappings: &ThinMappings,
    chunk_bytes: usize,
) -> io::Result<CopyStats> {
    let overflow = || io::Error::new(io::ErrorKind::InvalidInput, "range offset overflows u64");
    let block_bytes = mappings
        .block_sectors
        .checked_mul(SECTOR_BYTES)
        .ok_or_else(overflow)?;
    let mut buf = vec![0u8; chunk_bytes];
    let mut stats = CopyStats {
        scanned_chunks: 0,
        written_chunks: 0,
    };

    for range in &mappings.ranges {
        let offset = range.begin.checked_mul(block_bytes).ok_or_else(overflow)?;
        let mut remaining = range.length.checked_mul(block_bytes).ok_or_else(overflow)?;
        src.seek(SeekFrom::Start(offset))?;
        dst.seek(SeekFrom::Start(offset))?;

        while remaining > 0 {
            let want = remaining.min(chunk_bytes as u64) as usize;
            let n = read_full(src, &mut buf[..want])?;
            if n == 0 {
                // Device shorter than the mapping claims: stop this range.
                break;
            }
            dst.write_all(&buf[..n])?;
            stats.scanned_chunks += 1;
            stats.written_chunks += 1;
            remaining -= n as u64;
            if n < want {
                break;
            }
        }
    }

    dst.flush()?;
    Ok(stats)
}

// `Read::read` may return short counts on block devices; fill the buffer or hit EOF.
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match r.read(&mut buf[filled..])? {
            0 => break,
            n => filled += n,
        }
    }
    Ok(filled)
}

impl OpError for ThinCopyError {}

#[cfg(test)]
mod tests {
    use super::copy_ranges;
    use hyperrs_linux::dm::thin_dump::{BlockRange, ThinMappings};
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::io::{self, Cursor};
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
        #[strategy(64u64..600)] chunk: u64,
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

        copy_ranges(&mut Cursor::new(&src), &mut dst, &mappings, chunk as usize).unwrap();

        prop_assert_eq!(dst.into_inner(), oracle(&src, &mappings));
    }

    #[proptest]
    fn empty_ranges_write_nothing(
        #[strategy(proptest::collection::vec(any::<u8>(), 1..4096))] src: Vec<u8>,
        #[strategy(1u64..600)] chunk: u64,
    ) {
        let mut dst = Cursor::new(vec![SENTINEL; src.len()]);

        let stats = copy_ranges(
            &mut Cursor::new(&src),
            &mut dst,
            &mappings(1, &[]),
            chunk as usize,
        )
        .unwrap();

        prop_assert_eq!(stats.written_chunks, 0);
        prop_assert_eq!(dst.into_inner(), vec![SENTINEL; src.len()]);
    }

    #[rstest]
    #[case::one_chunk_per_range(1 << 20, &[(0, 3), (9, 1)], 2)]
    #[case::chunk_equal_to_a_block(512, &[(0, 3), (9, 1)], 4)]
    #[case::chunk_splitting_a_block(256, &[(0, 1)], 2)]
    #[case::uneven_tail(384, &[(0, 1)], 2)]
    #[case::range_past_the_device_end(1 << 20, &[(14, 4)], 1)]
    #[case::range_entirely_past_the_end(1 << 20, &[(20, 1)], 0)]
    fn chunk_accounting(
        #[case] chunk: usize,
        #[case] ranges: &[(u64, u64)],
        #[case] written_chunks: u64,
    ) {
        let src: Vec<u8> = (0..16 * 512).map(|i| (i % 251) as u8).collect();
        let mappings = mappings(1, ranges);
        let mut dst = Cursor::new(vec![SENTINEL; src.len()]);

        let stats = copy_ranges(&mut Cursor::new(&src), &mut dst, &mappings, chunk).unwrap();

        assert_eq!(stats.written_chunks, written_chunks);
        assert_eq!(stats.scanned_chunks, written_chunks);
        assert_eq!(dst.into_inner()[..src.len()], oracle(&src, &mappings)[..]);
    }

    #[rstest]
    #[case::block_size_overflows(u64::MAX, &[(0, 1)])]
    #[case::offset_overflows(1, &[(u64::MAX, 1)])]
    #[case::length_overflows(1, &[(0, u64::MAX)])]
    fn overflowing_geometry_is_refused_before_any_write(
        #[case] block_sectors: u64,
        #[case] ranges: &[(u64, u64)],
    ) {
        let mut dst = Cursor::new(vec![SENTINEL; 512]);

        let err = copy_ranges(
            &mut Cursor::new(vec![0u8; 512]),
            &mut dst,
            &mappings(block_sectors, ranges),
            512,
        )
        .unwrap_err();

        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(dst.into_inner(), vec![SENTINEL; 512]);
    }
}
