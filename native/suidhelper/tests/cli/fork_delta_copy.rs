//! `copy_ranges` turns a thin device's provisioned ranges into writes on the
//! fork's COW target; a skipped or invented byte silently corrupts the forked
//! image. Laws:
//!   * oracle: for ANY ranges (unsorted, overlapping, past the device end) the
//!     target equals the source on the union of the clipped ranges and is
//!     untouched everywhere else;
//!   * oracle: `written_chunks == scanned_chunks ==` the sum over ranges of
//!     `ceil(available bytes / chunk)`;
//!   * metamorphic: short reads, short writes and `Interrupted` reads (all
//!     legal per `std::io`) change nothing about the result;
//!   * any other I/O error from either side is propagated, never swallowed.

use hyper_suidhelper::cli::fork_delta::copy_ranges;
use hyperrs_linux::dm::thin_dump::{BlockRange, ThinMappings};
use proptest::prelude::*;
use std::io::{self, Cursor, Read, Seek, SeekFrom, Write};
use test_strategy::proptest;

const SENTINEL: u8 = 0xAA;
const SECTOR: u64 = 512;

fn mappings(block_sectors: u64, ranges: &[(u64, u64)]) -> ThinMappings {
    ThinMappings {
        block_sectors,
        ranges: ranges
            .iter()
            .map(|&(begin, length)| BlockRange { begin, length })
            .collect(),
    }
}

fn clipped(src_len: u64, block_bytes: u64, (begin, length): (u64, u64)) -> (u64, u64) {
    let start = (begin * block_bytes).min(src_len);
    let end = ((begin + length) * block_bytes).min(src_len);
    (start, end)
}

fn expected_target(src: &[u8], block_sectors: u64, ranges: &[(u64, u64)]) -> Vec<u8> {
    let bb = block_sectors * SECTOR;
    let mut out = vec![SENTINEL; src.len()];
    for &r in ranges {
        let (a, b) = clipped(src.len() as u64, bb, r);
        out[a as usize..b as usize].copy_from_slice(&src[a as usize..b as usize]);
    }
    out
}

fn expected_chunks(src_len: u64, block_sectors: u64, ranges: &[(u64, u64)], chunk: u64) -> u64 {
    let bb = block_sectors * SECTOR;
    ranges
        .iter()
        .map(|&r| {
            let (a, b) = clipped(src_len, bb, r);
            (b - a).div_ceil(chunk)
        })
        .sum()
}

struct Case {
    src: Vec<u8>,
    block_sectors: u64,
    ranges: Vec<(u64, u64)>,
    chunk: usize,
}

impl std::fmt::Debug for Case {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Case")
            .field("src_len", &self.src.len())
            .field("block_sectors", &self.block_sectors)
            .field("ranges", &self.ranges)
            .field("chunk", &self.chunk)
            .finish()
    }
}

fn case() -> impl Strategy<Value = Case> {
    (1u64..=4, 1usize..24)
        .prop_flat_map(|(block_sectors, blocks)| {
            let bb = (block_sectors * SECTOR) as usize;
            (
                Just(block_sectors),
                prop::collection::vec(any::<u8>(), (blocks * bb - bb / 2)..=(blocks * bb)),
                prop::collection::vec((0u64..(blocks as u64 + 4), 1u64..6), 0..8),
                prop_oneof![1usize..64, 64usize..4096, Just(1 << 20)],
            )
        })
        .prop_map(|(block_sectors, src, ranges, chunk)| Case {
            src,
            block_sectors,
            ranges,
            chunk,
        })
}

fn run(
    case: &Case,
    src: &mut (impl Read + Seek),
    dst: &mut (impl Write + Seek),
) -> io::Result<(u64, u64)> {
    copy_ranges(
        src,
        dst,
        &mappings(case.block_sectors, &case.ranges),
        case.chunk,
    )
    .map(|s| (s.scanned_chunks, s.written_chunks))
}

#[proptest(ProptestConfig::with_cases(512))]
fn any_ranges_copy_exactly_their_clipped_union_and_count_their_chunks(#[strategy(case())] c: Case) {
    let mut dst = Cursor::new(vec![SENTINEL; c.src.len()]);

    let (scanned, written) = run(&c, &mut Cursor::new(c.src.clone()), &mut dst).unwrap();

    let target = dst.into_inner();
    prop_assert_eq!(target.len(), c.src.len(), "wrote past the device end");
    prop_assert!(
        target == expected_target(&c.src, c.block_sectors, &c.ranges),
        "target differs from the clipped-union oracle"
    );
    let chunks = expected_chunks(
        c.src.len() as u64,
        c.block_sectors,
        &c.ranges,
        c.chunk as u64,
    );
    prop_assert_eq!(written, chunks);
    prop_assert_eq!(scanned, chunks);
}

struct Choppy<T> {
    inner: T,
    steps: Vec<usize>,
    at: usize,
    interrupt: bool,
}

impl<T> Choppy<T> {
    fn new(inner: T, steps: Vec<usize>, interrupt: bool) -> Self {
        Self {
            inner,
            steps,
            at: 0,
            interrupt,
        }
    }

    fn next(&mut self) -> Option<usize> {
        let step = self.steps[self.at % self.steps.len()];
        self.at += 1;
        if self.interrupt && self.at % 2 == 1 {
            None
        } else {
            Some(step)
        }
    }
}

impl<T: Read> Read for Choppy<T> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self.next() {
            None => Err(io::ErrorKind::Interrupted.into()),
            Some(n) => {
                let n = n.min(buf.len());
                self.inner.read(&mut buf[..n])
            }
        }
    }
}

impl<T: Write> Write for Choppy<T> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self.next() {
            None => Err(io::ErrorKind::Interrupted.into()),
            Some(n) => self.inner.write(&buf[..n.min(buf.len())]),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

impl<T: Seek> Seek for Choppy<T> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.inner.seek(pos)
    }
}

fn steps() -> impl Strategy<Value = Vec<usize>> {
    prop::collection::vec(1usize..700, 1..8)
}

fn baseline(c: &Case) -> (Vec<u8>, (u64, u64)) {
    let mut dst = Cursor::new(vec![SENTINEL; c.src.len()]);
    let stats = run(c, &mut Cursor::new(c.src.clone()), &mut dst).unwrap();
    (dst.into_inner(), stats)
}

#[proptest(ProptestConfig::with_cases(256))]
fn short_reads_and_short_writes_change_nothing(
    #[strategy(case())] c: Case,
    #[strategy(steps())] reads: Vec<usize>,
    #[strategy(steps())] writes: Vec<usize>,
) {
    let mut src = Choppy::new(Cursor::new(c.src.clone()), reads, false);
    let mut dst = Choppy::new(Cursor::new(vec![SENTINEL; c.src.len()]), writes, false);

    let stats = run(&c, &mut src, &mut dst).unwrap();

    let (target, expected_stats) = baseline(&c);
    prop_assert!(
        dst.inner.into_inner() == target,
        "short I/O changed the copy"
    );
    prop_assert_eq!(stats, expected_stats);
}

#[proptest(ProptestConfig::with_cases(128))]
fn interrupted_reads_are_retried_not_fatal(
    #[strategy(case())] c: Case,
    #[strategy(steps())] reads: Vec<usize>,
) {
    prop_assume!(!c.ranges.is_empty());
    let mut src = Choppy::new(Cursor::new(c.src.clone()), reads, true);
    let mut dst = Cursor::new(vec![SENTINEL; c.src.len()]);

    let got = run(&c, &mut src, &mut dst);

    let (target, expected_stats) = baseline(&c);
    prop_assert!(got.is_ok(), "an EINTR read aborted the fork: {:?}", got);
    prop_assert_eq!(got.unwrap(), expected_stats);
    prop_assert!(dst.into_inner() == target);
}

struct Failing<T> {
    inner: T,
    budget: usize,
}

impl<T: Read> Read for Failing<T> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if self.budget == 0 {
            return Err(io::Error::other("EIO"));
        }
        let cap = buf.len().min(self.budget);
        let n = self.inner.read(&mut buf[..cap])?;
        self.budget -= n;
        Ok(n)
    }
}

impl<T: Write> Write for Failing<T> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.budget == 0 {
            return Err(io::Error::other("EIO"));
        }
        let n = self.inner.write(&buf[..buf.len().min(self.budget)])?;
        self.budget -= n;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

impl<T: Seek> Seek for Failing<T> {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        self.inner.seek(pos)
    }
}

#[proptest(ProptestConfig::with_cases(256))]
fn an_io_error_on_either_side_is_propagated(
    #[strategy(case())] c: Case,
    #[strategy(any::<prop::sample::Index>())] cut: prop::sample::Index,
    fail_reads: bool,
) {
    let total: u64 = c
        .ranges
        .iter()
        .map(|&r| {
            let (a, b) = clipped(c.src.len() as u64, c.block_sectors * SECTOR, r);
            b - a
        })
        .sum();
    prop_assume!(total > 0);
    let budget = cut.index(total as usize);

    let got = if fail_reads {
        let mut src = Failing {
            inner: Cursor::new(c.src.clone()),
            budget,
        };
        run(&c, &mut src, &mut Cursor::new(vec![SENTINEL; c.src.len()]))
    } else {
        let mut dst = Failing {
            inner: Cursor::new(vec![SENTINEL; c.src.len()]),
            budget,
        };
        run(&c, &mut Cursor::new(c.src.clone()), &mut dst)
    };

    prop_assert!(
        got.is_err(),
        "an I/O error after {} of {} bytes was swallowed",
        budget,
        total
    );
}
