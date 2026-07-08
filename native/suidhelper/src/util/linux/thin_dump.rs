//! The Linux thin-provisioning-tools `thin_dump` XML document model,
//! deserialized whole via serde — sibling-device isolation and child ordering
//! are structural properties of the model rather than hand-maintained scan
//! state. Validation (the refusals) sits on top of the typed document.

use serde::Deserialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("thin_dump output has no <superblock> root")]
    NoSuperblock,
    #[error("thin device {0} not present in the metadata dump")]
    DeviceNotFound(u64),
    #[error(
        "device mappings incomplete: expected {expected} blocks, parsed {got} (truncated dump?)"
    )]
    Truncated { expected: u64, got: u64 },
    #[error("thin_dump output is not valid metadata XML: {0}")]
    Xml(String),
}

/// A thin device's provisioned map: pool block size (512-byte sectors) and
/// `(origin_begin, length)` ranges in pool blocks.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize)]
pub struct ThinMappings {
    pub block_sectors: u64,
    pub ranges: Vec<(u64, u64)>,
}

#[derive(Debug, Deserialize)]
struct Superblock {
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
    // `$value` collects the mixed range/single children in document order; a
    // self-closing empty device deserializes to the default empty list.
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
    fn range(&self) -> (u64, u64) {
        match *self {
            Mapping::Range {
                origin_begin,
                length,
            } => (origin_begin, length),
            Mapping::Single { origin_block } => (origin_block, 1),
        }
    }
}

/// Parse `thin_dump` XML, extracting `dev_id`'s provisioned ranges. An absent
/// device is an error — an empty result must always mean "device exists, has
/// no provisioned blocks", never "we looked at the wrong dump".
pub fn parse_mappings(xml: &str, dev_id: u64) -> Result<ThinMappings, Error> {
    ensure_superblock_root(xml)?;

    let superblock: Superblock =
        quick_xml::de::from_str(xml).map_err(|err| Error::Xml(err.to_string()))?;

    let device = superblock
        .devices
        .iter()
        .find(|device| device.dev_id == dev_id)
        .ok_or(Error::DeviceNotFound(dev_id))?;

    let ranges: Vec<(u64, u64)> = device.mappings.iter().map(Mapping::range).collect();

    let got: u64 = ranges.iter().map(|&(_, len)| len).sum();
    if got != device.mapped_blocks {
        return Err(Error::Truncated {
            expected: device.mapped_blocks,
            got,
        });
    }

    Ok(ThinMappings {
        block_sectors: superblock.data_block_size,
        ranges,
    })
}

// serde deserializes whatever root element exists into `Superblock` without
// checking its NAME — a dump whose root is not <superblock> must refuse as
// NoSuperblock, not as a missing-field soup. One event of lookahead pins it.
fn ensure_superblock_root(xml: &str) -> Result<(), Error> {
    use quick_xml::events::Event;

    let mut reader = quick_xml::Reader::from_str(xml);
    loop {
        match reader
            .read_event()
            .map_err(|err| Error::Xml(err.to_string()))?
        {
            Event::Start(e) | Event::Empty(e) => {
                return if e.name().as_ref() == b"superblock" {
                    Ok(())
                } else {
                    Err(Error::NoSuperblock)
                };
            }
            Event::Eof => return Err(Error::NoSuperblock),
            _ => {}
        }
    }
}
