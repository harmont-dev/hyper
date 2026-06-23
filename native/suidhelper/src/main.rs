// `&'static str` const generics (`SafeBin<"losetup">`) are nightly-only.
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

//! Tiny setuid-root helper for the unprivileged Hyper node.
//!
//! Hyper runs as a normal user but needs to attach loop devices and build
//! device-mapper tables (losetup / dmsetup / blockdev), which require root. This
//! helper is installed setuid root and exposes ONLY those operations, as a tree
//! of typed subcommands (one per tool, see `src/tools`), each taking its `--bin`,
//! plus a `sys-test` command to check installation.
//!
//! Privilege model: at startup we drop to the real uid; root is only ever held
//! inside a `Privileged` scope (see `setuid_privileged`), which wraps just the
//! tool's `run` (the `Command` call). Parsing the result happens after privileges
//! are dropped. Each subcommand prints its result as JSON on stdout; errors go to
//! stderr with a non-zero exit.
//!
//! Build & install:
//!   cargo build --release
//!   sudo install -o root -g root -m 4755 \
//!     target/release/hyper-suidhelper /usr/local/bin/hyper-suidhelper
//! Then: config :hyper, suid_helper: "/usr/local/bin/hyper-suidhelper"

mod tools;
mod util;
mod config;

use clap::{Parser, Subcommand};
use serde::Serialize;
use tools::Tool;
use util::setuid_privileged::{self, Privileged};

#[derive(Parser)]
#[command(name = "hyper-suidhelper", about = "Privileged device helper for the Hyper node")]
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
struct SysTest {
    sys_test: &'static str,
    hyper_base: String,
}

impl SysTest {
    fn perform() -> Result<Self, setuid_privileged::Error> {
        Privileged::smoke_test()?;
        Ok(Self {
            sys_test: "ok",
            hyper_base: crate::config::Config::get().hyper_base().to_string_lossy().into_owned(),
        })
    }
}

fn main() {
    // Privileges are already dropped to the real uid by a pre-main constructor
    // (see `setuid_privileged`); root is only re-acquired inside `Privileged`.
    // Load the config now - we are post-drop (real uid) and before any
    // `Privileged` scope, so the file is read unprivileged, never as root.
    config::Config::init();

    // Each command yields a serializable value (errors stringified to unify); we
    // render the final JSON line here.
    let output = match Cli::parse().command {
        Command::Tool(tool) => tool.run().map(Output::Tool).map_err(|e| e.to_string()),
        Command::SysTest => SysTest::perform().map(Output::SysTest).map_err(|e| e.to_string()),
    };

    match output.and_then(|o| serde_json::to_string(&o).map_err(|e| e.to_string())) {
        Ok(json) => println!("{json}"),
        Err(msg) => {
            eprintln!("{msg}");
            std::process::exit(2);
        }
    }
}
