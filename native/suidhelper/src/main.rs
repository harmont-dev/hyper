//! Tiny setuid-root helper for the unprivileged Hyper node — thin binary entry
//! point. The privilege model and command tree live in the `hyper_suidhelper`
//! library crate (`src/lib.rs`); this file only parses args and renders output.
//!
//! Privilege model: at startup we drop to the real uid; root is only ever held
//! inside a `Privileged` scope (see `setuid_privileged`), which wraps just the
//! tool's `run`. Each subcommand prints its result as JSON on stdout; errors go
//! to stderr with a non-zero exit.
//!
//! Build & install:
//!   cargo build --release
//!   sudo install -o root -g root -m 4755 \
//!     target/release/hyper-suidhelper /usr/local/bin/hyper-suidhelper
//! Then: config :hyper, suid_helper: "/usr/local/bin/hyper-suidhelper"

use clap::{Parser, Subcommand};
use hyper_suidhelper::config;
use hyper_suidhelper::tools::Tool;
use hyper_suidhelper::util::setuid_privileged::{self, Privileged};
use serde::Serialize;
use std::path::PathBuf;

#[derive(Parser)]
#[command(
    name = "hyper-suidhelper",
    about = "Privileged device helper for the Hyper node"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Device operations (one subcommand per tool).
    #[command(flatten)]
    Tool(Tool),
    /// Check the helper is correctly installed (can promote to root).
    SysTest,
    /// Print the build version and BLAKE3 checksum of this binary.
    Version,
}

/// The serializable result of a command, emitted as the JSON line on stdout.
/// Untagged so each command's own output shape is printed verbatim. Tools already
/// serialize themselves to a `Value`; `sys-test` carries its own struct.
#[derive(Serialize)]
#[serde(untagged)]
enum Output {
    Tool(serde_json::Value),
    SysTest(SysTest),
}

#[derive(Serialize)]
struct Version {
    version: &'static str,
    checksum_blake3: String,
}

impl Version {
    fn render() -> Self {
        Self {
            version: env!("CARGO_PKG_VERSION"),
            checksum_blake3: hyper_suidhelper::checksum::hex(),
        }
    }
}

#[derive(Serialize)]
struct SysTest {
    sys_test: &'static str,
    hyper_base: PathBuf,
}

impl SysTest {
    fn perform() -> Result<Self, setuid_privileged::Error> {
        Privileged::smoke_test()?;
        Ok(Self {
            sys_test: "ok",
            hyper_base: config::Config::get().hyper_base().to_path_buf(),
        })
    }
}

fn main() {
    let command = Cli::parse().command;

    // `version` is a pure self-report: it touches neither config nor privileges,
    // so render it before any setup that could fail (e.g. a missing config file).
    if let Command::Version = command {
        println!("{}", serde_json::to_string(&Version::render()).unwrap());
        return;
    }

    // Resolve the security gate before anything else reads it (the config load
    // below consults it). In release this is a no-op: the gate stays secure.
    hyper_suidhelper::security_gate::init();

    // Privileges are already dropped to the real uid by a pre-main constructor
    // (see `setuid_privileged`); root is only re-acquired inside `Privileged`.
    config::Config::init();

    // Each command yields a serializable value (errors stringified to unify); we
    // render the final JSON line here.
    let output = match command {
        Command::Tool(tool) => tool.run().map(Output::Tool).map_err(|e| e.to_string()),
        Command::SysTest => SysTest::perform()
            .map(Output::SysTest)
            .map_err(|e| e.to_string()),
        Command::Version => unreachable!("handled above"),
    };

    match output.and_then(|o| serde_json::to_string(&o).map_err(|e| e.to_string())) {
        Ok(json) => println!("{json}"),
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(2);
        }
    }
}
