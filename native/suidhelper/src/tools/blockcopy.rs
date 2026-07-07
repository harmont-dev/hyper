//! Chunked diff-copy between block devices. With a `reference` device given,
//! only chunks of `src` that differ from `reference` are written into `dst` —
//! the workhorse for materializing a fork's delta layer: `dst` is a writable
//! dm-snapshot over the reference, so every written chunk lands in its COW
//! exception store and nothing else does.

use super::IsTool;
use crate::util::safe_dev::BlockDev;
use clap::Args;
use serde::Serialize;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};

#[derive(Args)]
pub struct BlockcopyArgs {
    /// Device to copy from (the fork's point-in-time snapshot).
    #[arg(long)]
    src: BlockDev,
    /// Device to copy into (a writable dm-snapshot over `reference`).
    #[arg(long)]
    dst: BlockDev,
    /// Only chunks differing from this device are written.
    #[arg(long)]
    reference: Option<BlockDev>,
    /// Compare/copy granularity in bytes.
    #[arg(long, default_value_t = 1 << 20, value_parser = clap::value_parser!(u64).range(512..))]
    chunk_bytes: u64,
}

#[derive(Serialize)]
pub struct CopyStats {
    pub scanned_chunks: u64,
    pub written_chunks: u64,
}

/// Copy `src` into `dst` chunk-by-chunk, skipping chunks equal to `reference`.
/// `dst` is only ever written at offsets where content differs, so a dm-snapshot
/// `dst` records exactly the divergence.
pub fn diff_copy(
    src: &mut impl Read,
    mut reference: Option<&mut dyn Read>,
    dst: &mut (impl Write + Seek),
    chunk_bytes: usize,
) -> io::Result<CopyStats> {
    let mut src_buf = vec![0u8; chunk_bytes];
    let mut ref_buf = vec![0u8; chunk_bytes];
    let mut offset: u64 = 0;
    let mut stats = CopyStats {
        scanned_chunks: 0,
        written_chunks: 0,
    };

    loop {
        let n = read_full(src, &mut src_buf)?;
        if n == 0 {
            break;
        }
        stats.scanned_chunks += 1;

        let same = match reference.as_mut() {
            Some(r) => read_full(*r, &mut ref_buf)? == n && ref_buf[..n] == src_buf[..n],
            None => false,
        };

        if !same {
            dst.seek(SeekFrom::Start(offset))?;
            dst.write_all(&src_buf[..n])?;
            stats.written_chunks += 1;
        }

        offset += n as u64;
        if n < chunk_bytes {
            break;
        }
    }

    dst.flush()?;
    Ok(stats)
}

// `Read::read` may return short counts on block devices; fill the buffer or hit
// EOF. `?Sized` so the `&mut dyn Read` reference arm can call it too.
fn read_full(r: &mut (impl Read + ?Sized), buf: &mut [u8]) -> io::Result<usize> {
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
        match &self.args.reference {
            Some(r) => {
                let mut reference = File::open(r)?;
                diff_copy(&mut src, Some(&mut reference), &mut dst, chunk)
            }
            None => diff_copy(&mut src, None, &mut dst, chunk),
        }
    }

    fn parse(&self, res: Self::RunT) -> Result<CopyStats, Box<dyn std::error::Error>> {
        Ok(res?)
    }
}
