//! Build automation for the suidhelper. Run via the `cargo xtask` alias.
//!
//! Cargo has no native post-link hook, so the checksum-stamping and install
//! steps live here as ordinary cargo subcommands (one per module).

mod stamp;

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
}

struct Stderr;

impl log::Log for Stderr {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record) {
        if self.enabled(record.metadata()) {
            eprintln!("{}", record.args());
        }
    }

    fn flush(&self) {}
}

fn main() {
    log::set_logger(&Stderr).expect("no logger is installed before main");
    log::set_max_level(log::LevelFilter::Info);
    match Cli::parse().command {
        Command::Stamp => stamp::run(),
    }
}
