//! Extract a thin device's provisioned ranges from `thin_dump` XML.
//!
//! With an external-origin thin device, provisioned blocks are exactly the
//! blocks ever written — the divergence a fork publish must copy. The parser
//! reads thin_dump's output at the XML grammar level via `quick_xml`'s serde
//! support, not as a fixed layout — thin-provisioning-tools has two
//! implementations (the original C++ and the `pdata_tools` Rust rewrite)
//! whose formatting can drift (attribute order, whitespace, escaping) without
//! changing meaning, and a grammar-level parser is immune to that drift. See
//! `parse` for the document model.

pub mod parse;

pub use parse::{parse_mappings, Error, ThinMappings};

use std::io;
use std::path::PathBuf;
use std::process::{Command, Output};
use thiserror::Error as ThisError;

use super::IsTool;
use crate::util::safe_dev::LoopDev;
use clap::Args;

/// Errors of running the `thin_dump` binary itself; a bad parse of its
/// output composes in via `Parse`.
#[derive(Debug, ThisError)]
pub enum ToolError {
    #[error("running thin_dump: {0}")]
    Spawn(#[source] io::Error),
    #[error("thin_dump failed: {0}")]
    Failed(String),
    #[error(transparent)]
    Parse(#[from] parse::Error),
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
        let out = res.map_err(ToolError::Spawn)?;
        if !out.status.success() {
            return Err(
                ToolError::Failed(String::from_utf8_lossy(&out.stderr).trim().to_string()).into(),
            );
        }

        let xml = String::from_utf8_lossy(&out.stdout);
        Ok(parse_mappings(&xml, self.args.dev_id).map_err(ToolError::from)?)
    }
}
