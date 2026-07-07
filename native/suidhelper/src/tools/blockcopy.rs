//! Chunked ranged copy between block devices. Only the block ranges listed in
//! a metadata-supplied range file are copied from `src` into `dst` — the
//! workhorse for materializing a fork's delta layer: `dst` is a writable
//! dm-snapshot over the origin, so every written chunk lands in its COW
//! exception store and nothing else does. No comparison mode exists; the
//! ranges are trusted as the exact divergence.

use super::IsTool;
use crate::util::safe_dev::BlockDev;
use clap::Args;
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};

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
    #[arg(long)]
    src: BlockDev,
    /// Device to copy into (a writable dm-snapshot over the origin).
    #[arg(long)]
    dst: BlockDev,
    /// Copy only these block ranges (JSON file from `thin-dump`).
    #[arg(long, value_parser = range_spec_from_file)]
    ranges: RangeSpec,
    /// Copy granularity in bytes.
    #[arg(long, default_value_t = 1 << 20, value_parser = clap::value_parser!(u64).range(512..))]
    chunk_bytes: u64,
}

#[derive(Serialize)]
pub struct CopyStats {
    pub scanned_chunks: u64,
    pub written_chunks: u64,
}

/// Copy exactly `spec`'s block ranges from `src` into `dst` at identical
/// offsets. The dm-thin metadata already told us where the divergence is, so
/// nothing is read outside the listed ranges.
pub fn copy_ranges(
    src: &mut (impl Read + Seek),
    dst: &mut (impl Write + Seek),
    spec: &RangeSpec,
    chunk_bytes: usize,
) -> io::Result<CopyStats> {
    let overflow = || io::Error::new(io::ErrorKind::InvalidInput, "range offset overflows u64");
    let block_bytes = spec.block_sectors.checked_mul(512).ok_or_else(overflow)?;
    let mut buf = vec![0u8; chunk_bytes];
    let mut stats = CopyStats {
        scanned_chunks: 0,
        written_chunks: 0,
    };

    for &(begin, len) in &spec.ranges {
        let offset = begin.checked_mul(block_bytes).ok_or_else(overflow)?;
        let mut remaining = len.checked_mul(block_bytes).ok_or_else(overflow)?;
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

pub struct Blockcopy {
    args: BlockcopyArgs,
}

impl Blockcopy {
    pub fn new(args: BlockcopyArgs) -> Self {
        Self { args }
    }
}

impl IsTool for Blockcopy {
    type Args = BlockcopyArgs;
    type Output = CopyStats;
    type RunT = io::Result<CopyStats>;

    fn run_privileged(&self) -> Self::RunT {
        let mut src = File::open(&self.args.src)?;
        let mut dst = OpenOptions::new().write(true).open(&self.args.dst)?;
        let chunk = self.args.chunk_bytes as usize;

        copy_ranges(&mut src, &mut dst, &self.args.ranges, chunk)
    }

    fn parse(&self, res: Self::RunT) -> Result<CopyStats, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}
