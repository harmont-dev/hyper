//! Chunked ranged copy between block devices. Only the block ranges listed in
//! a metadata-supplied range file are copied from `src` into `dst` — the
//! workhorse for materializing a fork's delta layer: `dst` is a writable
//! dm-snapshot over the origin, so every written chunk lands in its COW
//! exception store and nothing else does. No comparison mode exists; the
//! ranges are trusted as the exact divergence.

use super::IsTool;
use crate::tools::HyperDmName;
use clap::Args;
use derive_more::Constructor;
use hyperrs_process::privilege::Root;
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{self, BufWriter, Read, Seek, SeekFrom, Write};

/// A disk sector is 512 bytes by kernel convention, independent of the
/// device's physical sector size.
const SECTOR_BYTES: u64 = 512;

const COPY_BUF_BYTES: usize = 1 << 20;

/// A provisioned-range list, the JSON `thin-dump` emits: pool block size in
/// 512-byte sectors, and `(begin, length)` ranges in pool blocks.
#[derive(Debug, Clone, Deserialize)]
pub struct RangeSpec {
    pub block_sectors: u64,
    pub ranges: Vec<(u64, u64)>,
}

// Loaded at clap parse time — unprivileged, before any root window. The serde
// detail is deliberately not echoed: the file path is caller-supplied and its
// content must never leak through stderr.
fn range_spec_from_file(path: &str) -> Result<RangeSpec, String> {
    let body = std::fs::read_to_string(path).map_err(|e| format!("reading ranges file: {e}"))?;
    serde_json::from_str(&body).map_err(|_| "ranges file is not valid range JSON".to_string())
}

#[derive(Args)]
pub struct BlockcopyArgs {
    /// Device to copy from (the fork's point-in-time snapshot).
    #[arg(long, value_parser = HyperDmName::from_device_path)]
    src: HyperDmName,
    /// Device to copy into (a writable dm-snapshot over the origin).
    #[arg(long, value_parser = HyperDmName::from_device_path)]
    dst: HyperDmName,
    /// Copy only these block ranges (JSON file from `thin-dump`).
    #[arg(long, value_parser = range_spec_from_file)]
    ranges: RangeSpec,
}

#[derive(Serialize)]
pub struct CopyStats {
    pub copied_bytes: u64,
}

/// Copy exactly `spec`'s block ranges from `src` into `dst` at identical
/// offsets. The dm-thin metadata already told us where the divergence is, so
/// nothing is read outside the listed ranges.
pub fn copy_ranges(
    src: &mut (impl Read + Seek),
    dst: &mut (impl Write + Seek),
    spec: &RangeSpec,
) -> io::Result<CopyStats> {
    let overflow = || io::Error::new(io::ErrorKind::InvalidInput, "range offset overflows u64");
    let block_bytes = spec
        .block_sectors
        .checked_mul(SECTOR_BYTES)
        .ok_or_else(overflow)?;
    let mut dst = BufWriter::with_capacity(COPY_BUF_BYTES, dst);
    let copied_bytes = spec
        .ranges
        .iter()
        .map(|&(begin, len)| {
            let offset = begin.checked_mul(block_bytes).ok_or_else(overflow)?;
            let len = len.checked_mul(block_bytes).ok_or_else(overflow)?;
            src.seek(SeekFrom::Start(offset))?;
            dst.seek(SeekFrom::Start(offset))?;
            io::copy(&mut src.by_ref().take(len), &mut dst)
        })
        .sum::<io::Result<u64>>()?;

    dst.flush()?;
    Ok(CopyStats { copied_bytes })
}

#[derive(Constructor)]
pub struct Blockcopy {
    args: BlockcopyArgs,
}

impl IsTool for Blockcopy {
    type Args = BlockcopyArgs;
    type Output = CopyStats;
    type RunT = io::Result<CopyStats>;

    fn run_privileged(&self, _root: &Root<'_>) -> Self::RunT {
        let mut src = File::open(self.args.src.path().as_path())?;
        let mut dst = OpenOptions::new()
            .write(true)
            .open(self.args.dst.path().as_path())?;
        copy_ranges(&mut src, &mut dst, &self.args.ranges)
    }

    fn parse(&self, res: Self::RunT) -> Result<CopyStats, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}
