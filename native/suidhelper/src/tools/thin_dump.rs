//! Extract a thin device's provisioned ranges from `thin_dump` XML.
//!
//! With an external-origin thin device, provisioned blocks are exactly the
//! blocks ever written — the divergence a fork publish must copy. The parser
//! is line-oriented over thin_dump's machine-generated output and keys every
//! attribute lookup on ` key="` (leading space), so `snap_time` can never
//! satisfy a lookup for `time`.
//!
//! The device's own `mapped_blocks` attribute is cross-checked against the
//! number of ranges actually parsed, so a dump truncated mid-device (a
//! killed/crashed `thin_dump`) is an error rather than a silently short
//! result.

use serde::Serialize;
use std::io;
use std::path::PathBuf;
use std::process::{Command, Output};
use thiserror::Error as ThisError;

use super::IsTool;
use crate::util::safe_dev::LoopDev;
use clap::Args;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("thin_dump output has no <superblock> element")]
    NoSuperblock,
    #[error("thin device {0} not present in the metadata dump")]
    DeviceNotFound(u64),
    #[error("expected attribute `{0}` missing")]
    MissingAttr(&'static str),
    #[error("attribute `{0}` is not a u64")]
    BadAttr(&'static str),
    #[error(
        "device mappings incomplete: expected {expected} blocks, parsed {got} (truncated dump?)"
    )]
    Truncated { expected: u64, got: u64 },
    #[error("running thin_dump: {0}")]
    Spawn(#[source] io::Error),
    #[error("thin_dump failed: {0}")]
    Failed(String),
}

/// A thin device's provisioned map: pool block size (512-byte sectors) and
/// `(origin_begin, length)` ranges in pool blocks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ThinMappings {
    pub block_sectors: u64,
    pub ranges: Vec<(u64, u64)>,
}

/// Parse `thin_dump` XML, extracting `dev_id`'s provisioned ranges. An absent
/// device is an error — an empty result must always mean "device exists, has
/// no provisioned blocks", never "we looked at the wrong dump".
pub fn parse_mappings(xml: &str, dev_id: u64) -> Result<ThinMappings, Error> {
    let mut block_sectors: Option<u64> = None;
    let mut expected_blocks: Option<u64> = None;
    let mut in_target = false;
    let mut found = false;
    let mut ranges = Vec::new();

    for raw in xml.lines() {
        let line = raw.trim_start();

        if line.starts_with("<superblock") {
            block_sectors = Some(attr_u64(line, "data_block_size")?);
        } else if line.starts_with("<device") {
            if attr_u64(line, "dev_id")? == dev_id {
                found = true;
                expected_blocks = Some(attr_u64(line, "mapped_blocks")?);
                // An empty device self-closes; no </device> follows.
                in_target = !line.ends_with("/>");
            }
        } else if line.starts_with("</device") {
            in_target = false;
        } else if in_target && line.starts_with("<range_mapping") {
            ranges.push((attr_u64(line, "origin_begin")?, attr_u64(line, "length")?));
        } else if in_target && line.starts_with("<single_mapping") {
            ranges.push((attr_u64(line, "origin_block")?, 1));
        }
    }

    match (block_sectors, found) {
        (Some(block_sectors), true) => {
            let got: u64 = ranges.iter().map(|&(_, len)| len).sum();
            let expected = expected_blocks.unwrap_or(0);
            if got != expected {
                return Err(Error::Truncated { expected, got });
            }
            Ok(ThinMappings {
                block_sectors,
                ranges,
            })
        }
        (None, _) => Err(Error::NoSuperblock),
        (_, false) => Err(Error::DeviceNotFound(dev_id)),
    }
}

// ` key="` with the leading space, so a key can never match another key's
// suffix (e.g. `time` vs `snap_time`), independent of attribute order.
fn attr_u64(line: &str, key: &'static str) -> Result<u64, Error> {
    let needle = format!(" {key}=\"");
    let start = line.find(&needle).ok_or(Error::MissingAttr(key))? + needle.len();
    let rest = &line[start..];
    let end = rest.find('"').ok_or(Error::MissingAttr(key))?;
    rest[..end].parse().map_err(|_| Error::BadAttr(key))
}

#[derive(Args)]
pub struct ThinDumpArgs {
    /// The pool's metadata loop device.
    #[arg(long)]
    meta: LoopDev,
    /// The thin device id whose provisioned ranges to extract.
    #[arg(long)]
    dev_id: u64,
}

pub struct ThinDump {
    bin: PathBuf,
    args: ThinDumpArgs,
}

impl ThinDump {
    pub fn new(bin: PathBuf, args: ThinDumpArgs) -> Self {
        Self { bin, args }
    }
}

impl IsTool for ThinDump {
    type Args = ThinDumpArgs;
    type Output = ThinMappings;
    type RunT = io::Result<Output>;

    fn run_privileged(&self) -> Self::RunT {
        // --metadata-snap reads the caller-reserved metadata snapshot, the
        // only safe way to dump a live pool's metadata device.
        Command::new(&self.bin)
            .arg("--metadata-snap")
            .arg(self.args.meta.as_ref())
            .env_clear()
            .output()
    }

    fn parse(&self, res: Self::RunT) -> Result<ThinMappings, Box<dyn std::error::Error>> {
        let out = res.map_err(Error::Spawn)?;
        if !out.status.success() {
            return Err(
                Error::Failed(String::from_utf8_lossy(&out.stderr).trim().to_string()).into(),
            );
        }

        let xml = String::from_utf8_lossy(&out.stdout);
        Ok(parse_mappings(&xml, self.args.dev_id)?)
    }
}
