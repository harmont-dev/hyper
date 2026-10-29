//! `thin-dump` utilities.
use super::ThinId;
use crate::fs::file::{IsBlockDevice, SafeFile};
use crate::process::binary::RootSafeBin;
use derive_more::{Constructor, Into};
use serde::Deserialize;
use std::io;
use std::os::unix::io::AsRawFd;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum DumpError {
    #[error("passing the metadata device: {0}")]
    Inherit(#[source] nix::Error),
    #[error("running thin_dump: {0}")]
    Spawn(#[source] io::Error),
    #[error("thin_dump failed: {0}")]
    Failed(String),
}

#[derive(Debug, ThisError)]
pub enum ParseError {
    #[error("thin_dump output is not UTF-8: {0}")]
    Utf8(#[source] std::str::Utf8Error),
    #[error("thin_dump output is not valid metadata XML: {0}")]
    Xml(String),
}

#[derive(Debug, ThisError)]
pub enum MappingsError {
    #[error("thin device {0} not present in the metadata dump")]
    DeviceNotFound(ThinId),
    #[error(
        "device mappings incomplete: expected {expected} blocks, parsed {got} (truncated dump?)"
    )]
    Truncated { expected: u64, got: u64 },
}

#[derive(Constructor)]
pub struct ThinDump {
    bin: RootSafeBin<"thin_dump">,
}

impl ThinDump {
    pub fn dump<R, O>(
        &self,
        metadata: &SafeFile<IsBlockDevice, R, O>,
        id: ThinId,
    ) -> Result<MetadataDump, DumpError> {
        let inherited = metadata.inheritable().map_err(DumpError::Inherit)?;
        let out = self
            .bin
            .command()
            .args(["--metadata-snap", "--dev-id", &id.to_string()])
            .arg(format!("/proc/self/fd/{}", inherited.as_raw_fd()))
            .env_clear()
            .output()
            .map_err(DumpError::Spawn)?;

        if !out.status.success() {
            return Err(DumpError::Failed(
                String::from_utf8_lossy(&out.stderr).trim().to_string(),
            ));
        }

        Ok(MetadataDump { xml: out.stdout })
    }
}

#[derive(Debug, Clone)]
pub struct MetadataDump {
    xml: Vec<u8>,
}

impl MetadataDump {
    pub fn parse(&self) -> Result<Superblock, ParseError> {
        let xml = std::str::from_utf8(&self.xml).map_err(ParseError::Utf8)?;
        let Root::Superblock(superblock) =
            quick_xml::de::from_str(xml).map_err(|err| ParseError::Xml(err.to_string()))?;
        Ok(superblock)
    }
}

impl Superblock {
    pub fn mappings(&self, id: ThinId) -> Result<ThinMappings, MappingsError> {
        let device = self
            .devices
            .iter()
            .find(|device| device.dev_id == u64::from(id))
            .ok_or(MappingsError::DeviceNotFound(id))?;

        let ranges: Vec<BlockRange> = device.mappings.iter().map(Mapping::range).collect();

        let got: u64 = ranges.iter().map(|range| range.length).sum();
        if got != device.mapped_blocks {
            return Err(MappingsError::Truncated {
                expected: device.mapped_blocks,
                got,
            });
        }

        Ok(ThinMappings {
            block_sectors: self.data_block_size,
            ranges,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ThinMappings {
    pub block_sectors: u64,
    pub ranges: Vec<BlockRange>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, Into)]
#[serde(into = "(u64, u64)")]
pub struct BlockRange {
    pub begin: u64,
    pub length: u64,
}

#[derive(Debug, Deserialize)]
enum Root {
    #[serde(rename = "superblock")]
    Superblock(Superblock),
}

#[derive(Debug, Deserialize)]
pub struct Superblock {
    #[serde(rename = "@data_block_size")]
    data_block_size: u64,
    #[serde(rename = "device", default)]
    devices: Vec<Device>,
}

#[derive(Debug, Deserialize)]
struct Device {
    #[serde(rename = "@dev_id")]
    dev_id: u64,
    #[serde(rename = "@mapped_blocks")]
    mapped_blocks: u64,
    #[serde(rename = "$value", default)]
    mappings: Vec<Mapping>,
}

#[derive(Debug, Deserialize)]
enum Mapping {
    #[serde(rename = "range_mapping")]
    Range {
        #[serde(rename = "@origin_begin")]
        origin_begin: u64,
        #[serde(rename = "@length")]
        length: u64,
    },
    #[serde(rename = "single_mapping")]
    Single {
        #[serde(rename = "@origin_block")]
        origin_block: u64,
    },
}

impl Mapping {
    fn range(&self) -> BlockRange {
        match *self {
            Mapping::Range {
                origin_begin,
                length,
            } => BlockRange {
                begin: origin_begin,
                length,
            },
            Mapping::Single { origin_block } => BlockRange {
                begin: origin_block,
                length: 1,
            },
        }
    }
}
