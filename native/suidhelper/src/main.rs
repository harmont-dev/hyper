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
use hyper_suidhelper::process::privilege::{self, Unprivileged};
use hyper_suidhelper::tools::jailer::{self, JailerArgs};
use hyper_suidhelper::tools::Tool;
use serde::Serialize;
use std::path::PathBuf;

hyper_suidhelper::setuid_main!(run);

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
    /// Validate the caller's args, become root, and `execve` the firecracker
    /// jailer in our place. Prints nothing on success (the image is replaced).
    Jailer(JailerArgs),
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
            checksum_blake3: hyperrs_elfsum::checksum!().hex(),
        }
    }
}

#[derive(Serialize)]
struct SysTest {
    sys_test: &'static str,
    hyper_base: PathBuf,
}

impl SysTest {
    fn perform(token: &mut Unprivileged) -> Result<Self, privilege::Error> {
        drop(token.elevate()?);
        Ok(Self {
            sys_test: "ok",
            hyper_base: config::Config::get().hyper_base().to_path_buf(),
        })
    }
}

fn run(mut token: Unprivileged) {
    let command = Cli::parse().command;

    // `version` is a pure self-report: it touches neither config nor privileges,
    // so render it before any setup that could fail (e.g. a missing config file).
    if let Command::Version = command {
        println!("{}", serde_json::to_string(&Version::render()).unwrap());
        return;
    }

    // Privileges are already dropped to the real uid by a pre-main constructor
    // (see `setuid_privileged`); root is only re-acquired inside `Privileged`.
    config::Config::init();

    // Each command yields a serializable value (errors stringified to unify); we
    // render the final JSON line here. The jailer is the exception: it `execve`s
    // in place, so on success it never returns and never emits JSON, and on
    // failure it reports to stderr and exits before reaching the JSON pipeline.
    let output = match command {
        Command::Tool(tool) => tool
            .run(&mut token)
            .map(Output::Tool)
            .map_err(|e| e.to_string()),
        Command::SysTest => SysTest::perform(&mut token)
            .map(Output::SysTest)
            .map_err(|e| e.to_string()),
        Command::Jailer(args) => {
            let e = jailer::run(args, token).expect_err("jailer::run only returns on error");
            eprintln!("{e}");
            // _exit bypasses atexit handlers; safe because we are permanently root
            // at this point and must not run any cleanup registered before escalation.
            unsafe { nix::libc::_exit(2) }
        }
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
