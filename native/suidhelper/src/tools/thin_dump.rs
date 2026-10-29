//! Extract a thin device's provisioned ranges from `thin_dump` XML.
//!
//! With an external-origin thin device, provisioned blocks are exactly the
//! blocks ever written — the divergence a fork publish must copy. The parser
//! reads thin_dump's output at the XML grammar level via `quick_xml`'s serde
//! support, not as a fixed layout — thin-provisioning-tools has two
//! implementations (the original C++ and the `pdata_tools` Rust rewrite)
//! whose formatting can drift (attribute order, whitespace, escaping) without
//! changing meaning, and a grammar-level parser is immune to that drift. See
//! `crate::linux::dm::thin_dump` for the document model.

use thiserror::Error as ThisError;

use super::IsTool;
use crate::fs::file::{self, Any, IsBlockDevice, OpenFlags, SafeFile};
use crate::fs::path;
use crate::linux::dm::thin_dump::{self as dump, DumpError, MetadataDump, ThinMappings};
use crate::linux::dm::ThinId;
use crate::linux::loopdev::LoopDevNum;
use crate::process::binary::RootSafeBin;
use clap::Args;

#[derive(Debug, ThisError)]
pub enum ToolError {
    #[error("metadata device path: {0}")]
    Path(#[from] path::ValidationError),
    #[error("opening metadata device: {0}")]
    Open(#[from] file::ValidationError),
    #[error(transparent)]
    Dump(#[from] DumpError),
}

#[derive(Args)]
pub struct ThinDumpArgs {
    /// The pool's metadata loop device.
    #[arg(long)]
    meta: LoopDevNum,
    /// The thin device id whose provisioned ranges to extract.
    #[arg(long, value_parser = parse_thin_id)]
    dev_id: ThinId,
}

fn parse_thin_id(s: &str) -> Result<ThinId, String> {
    let raw: u32 = s
        .parse()
        .map_err(|e: std::num::ParseIntError| e.to_string())?;
    ThinId::new(raw).map_err(|e| e.to_string())
}

pub struct ThinDump {
    thin_dump: dump::ThinDump,
    args: ThinDumpArgs,
}

impl ThinDump {
    pub fn new(bin: RootSafeBin<"thin_dump">, args: ThinDumpArgs) -> Self {
        Self {
            thin_dump: dump::ThinDump::new(bin),
            args,
        }
    }
}

impl IsTool for ThinDump {
    type Args = ThinDumpArgs;
    type Output = ThinMappings;
    type RunT = Result<MetadataDump, ToolError>;

    fn run_privileged(&self) -> Self::RunT {
        let meta = self.args.meta.path()?;
        let device = SafeFile::<IsBlockDevice, Any, Any>::open(&meta, OpenFlags::RDONLY)?;
        // --metadata-snap reads the caller-reserved metadata snapshot, the
        // only safe way to dump a live pool's metadata device.
        Ok(self.thin_dump.dump(&device, self.args.dev_id)?)
    }

    fn parse(&self, res: Self::RunT) -> Result<ThinMappings, Box<dyn std::error::Error>> {
        Ok(res?.parse()?.mappings(self.args.dev_id)?)
    }
}
