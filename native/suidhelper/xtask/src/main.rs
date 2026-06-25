//! Build automation for the suidhelper. Run via the `cargo xtask` alias.
//!
//! Cargo has no native post-link hook, so the checksum-stamping and install
//! steps live here as ordinary cargo subcommands (one per module).

mod install;
mod stamp;

use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};

/// Name of the helper package/binary these tasks operate on.
const BIN: &str = "hyper-suidhelper";

#[derive(Parser)]
#[command(name = "xtask", about = "Build automation for hyper-suidhelper")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Build the release binary and write its checksum into the ELF.
    Stamp,
    /// Stamp, then install the binary setuid-root.
    Install,
}

fn main() {
    match Cli::parse().command {
        Command::Stamp => {
            stamp::run();
        }
        Command::Install => install::run(),
    }
}

/// The workspace `target/` dir (xtask's manifest sits one level below the root).
fn target_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("xtask has no parent dir")
        .join("target")
}
