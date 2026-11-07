//! `thin-dump` utilities.
use super::ThinId;
use derive_more::{Constructor, Into};
use hyperrs_fs::file::{IsBlockDevice, SafeFile};
use hyperrs_process::binary::RootSafeBin;
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

#[cfg(test)]
mod tests {
    use super::{BlockRange, MappingsError, MetadataDump, ParseError, ThinId, ThinMappings};
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::assert_matches;
    use test_strategy::proptest;

    #[derive(Debug, Clone)]
    enum M {
        Range { begin: u64, len: u64 },
        Single { block: u64 },
    }

    impl M {
        fn len(&self) -> u64 {
            match *self {
                M::Range { len, .. } => len,
                M::Single { .. } => 1,
            }
        }

        fn range(&self) -> BlockRange {
            match *self {
                M::Range { begin, len } => BlockRange { begin, length: len },
                M::Single { block } => BlockRange {
                    begin: block,
                    length: 1,
                },
            }
        }
    }

    fn mapping() -> impl Strategy<Value = M> {
        prop_oneof![
            (0u64..1 << 20, 1u64..512).prop_map(|(begin, len)| M::Range { begin, len }),
            (0u64..1 << 20).prop_map(|block| M::Single { block }),
        ]
    }

    fn mapped_blocks(maps: &[M]) -> u64 {
        maps.iter().map(M::len).sum()
    }

    fn render_device(dev_id: u32, mapped: u64, maps: &[M]) -> String {
        let open = format!(
            "  <device dev_id=\"{dev_id}\" mapped_blocks=\"{mapped}\" transaction=\"0\" creation_time=\"0\" snap_time=\"1\""
        );
        if maps.is_empty() {
            return format!("{open}/>\n");
        }

        let mut s = format!("{open}>\n");
        for m in maps {
            s.push_str(&match *m {
                M::Range { begin, len } => format!(
                    "    <range_mapping origin_begin=\"{begin}\" data_begin=\"7\" length=\"{len}\" time=\"0\"/>\n"
                ),
                M::Single { block } => format!(
                    "    <single_mapping origin_block=\"{block}\" data_block=\"9\" time=\"0\"/>\n"
                ),
            });
        }
        s.push_str("  </device>\n");
        s
    }

    fn render(block_sectors: u64, devices: &[(u32, u64, Vec<M>)]) -> String {
        let mut s = format!(
            "<superblock uuid=\"\" time=\"1\" transaction=\"2\" flags=\"0\" version=\"2\" data_block_size=\"{block_sectors}\" nr_data_blocks=\"16384\">\n"
        );
        for (id, mapped, maps) in devices {
            s.push_str(&render_device(*id, *mapped, maps));
        }
        s.push_str("</superblock>\n");
        s
    }

    fn device(id: u32, maps: Vec<M>) -> (u32, u64, Vec<M>) {
        (id, mapped_blocks(&maps), maps)
    }

    fn id(n: u32) -> ThinId {
        ThinId::new(n).unwrap()
    }

    fn dump(xml: impl Into<Vec<u8>>) -> MetadataDump {
        MetadataDump { xml: xml.into() }
    }

    fn mappings(xml: &str, n: u32) -> Result<ThinMappings, MappingsError> {
        dump(xml).parse().unwrap().mappings(id(n))
    }

    #[proptest]
    fn extracts_exactly_the_target_devices_ranges(
        #[strategy(1u64..4096)] block_sectors: u64,
        #[strategy(proptest::collection::vec(mapping(), 0..64))] target: Vec<M>,
        #[strategy(proptest::collection::vec(mapping(), 0..64))] sibling: Vec<M>,
    ) {
        let xml = render(
            block_sectors,
            &[
                device(1, sibling.clone()),
                device(3, target.clone()),
                device(5, sibling),
            ],
        );

        let got = mappings(&xml, 3).unwrap();

        prop_assert_eq!(got.block_sectors, block_sectors);
        prop_assert_eq!(got.ranges, target.iter().map(M::range).collect::<Vec<_>>());
    }

    #[proptest]
    fn absent_device_is_an_error_not_empty(
        #[strategy(proptest::collection::vec(mapping(), 0..16))] maps: Vec<M>,
    ) {
        let xml = render(128, &[device(1, maps)]);
        assert_matches!(
            mappings(&xml, 99),
            Err(MappingsError::DeviceNotFound(got)) if got == id(99)
        );
    }

    #[proptest]
    fn mapped_blocks_disagreeing_with_the_mappings_is_an_error(
        #[strategy(proptest::collection::vec(mapping(), 0..64))] target: Vec<M>,
        #[strategy(prop_oneof![1i64..64, -64i64..0])] skew: i64,
    ) {
        let actual = mapped_blocks(&target);
        let claimed = actual.saturating_add_signed(skew);
        prop_assume!(claimed != actual);
        let xml = render(128, &[(3, claimed, target)]);

        assert_matches!(
            mappings(&xml, 3),
            Err(MappingsError::Truncated { expected, got }) if expected == claimed && got == actual
        );
    }

    #[rstest]
    fn non_utf8_output_is_an_error() {
        let mut xml = render(128, &[device(3, vec![])]).into_bytes();
        xml.insert(1, 0xff);
        assert_matches!(dump(xml).parse(), Err(ParseError::Utf8(_)));
    }

    #[rstest]
    fn empty_self_closing_device_parses_to_no_ranges() {
        let xml = render(128, &[device(3, vec![])]);
        assert_eq!(
            mappings(&xml, 3).unwrap(),
            ThinMappings {
                block_sectors: 128,
                ranges: vec![]
            }
        );
    }

    #[rstest]
    fn attribute_lookup_is_by_exact_name() {
        let xml = "<superblock uuid=\"\" time=\"1\" transaction=\"2\" flags=\"0\" version=\"2\" data_block_size=\"128\" nr_data_blocks=\"1\">\n  <device snap_dev_id=\"9\" dev_id=\"3\" mapped_blocks=\"1\" transaction=\"0\" creation_time=\"0\" snap_time=\"1\">\n    <range_mapping origin_begin=\"0\" data_begin=\"0\" length=\"1\" time=\"0\"/>\n  </device>\n</superblock>\n";
        assert_eq!(
            mappings(xml, 3).unwrap().ranges,
            [BlockRange {
                begin: 0,
                length: 1
            }]
        );
    }

    #[rstest]
    fn layout_variance_is_irrelevant() {
        let xml = "<superblock nr_data_blocks=\"16384\" data_block_size=\"128\" uuid=\"a&quot;b\" time=\"1\" transaction=\"2\" flags=\"0\" version=\"2\"><device snap_time=\"1\" dev_id=\"3\" mapped_blocks=\"9\" transaction=\"0\" creation_time=\"0\"><range_mapping length=\"8\" origin_begin=\"0\" data_begin=\"100\" time=\"0\"/><single_mapping data_block=\"200\" origin_block=\"42\" time=\"0\"/></device></superblock>";
        assert_eq!(
            mappings(xml, 3).unwrap(),
            ThinMappings {
                block_sectors: 128,
                ranges: vec![
                    BlockRange {
                        begin: 0,
                        length: 8
                    },
                    BlockRange {
                        begin: 42,
                        length: 1
                    },
                ]
            }
        );
    }

    fn cut_after_first_device_line() -> String {
        let whole = render(128, &[device(3, vec![M::Range { begin: 0, len: 8 }])]);
        whole.lines().take(3).map(|l| format!("{l}\n")).collect()
    }

    #[rstest]
    #[case::no_superblock("<device dev_id=\"3\" mapped_blocks=\"0\"></device>".to_string())]
    #[case::unterminated_tag(
        "<superblock data_block_size=\"128\"><device dev_id=\"3\"".to_string()
    )]
    #[case::cut_mid_document(cut_after_first_device_line())]
    fn malformed_or_cut_xml_is_an_error_not_a_guess(#[case] xml: String) {
        assert_matches!(
            dump(xml.as_str()).parse(),
            Err(ParseError::Xml(_)),
            "{xml:?}"
        );
    }
}
