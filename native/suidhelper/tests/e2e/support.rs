//! Shared spawn support for the e2e suite: run the helper binary with a
//! scrubbed environment, proving it depends only on its two env seams.
//!
//! One deliberate exception to the scrub: `LLVM_PROFILE_FILE`. Under
//! `cargo llvm-cov` the helper binary is instrumented and its profile runtime
//! writes a `.profraw` to that path at exit (`%p` in the pattern keeps the
//! child's file distinct from the test process's own). A bare `env_clear()`
//! silently discards it, so every e2e execution of `src/main.rs` counted
//! nothing toward coverage.

// Each [[test]] target compiles its own copy of this module and not every
// target uses every item.
#![allow(dead_code)]

use std::path::Path;
use std::process::{Command, Output};

pub const BIN: &str = env!("CARGO_BIN_EXE_hyper-suidhelper");

pub fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

/// Run the helper with the security gate open and the config path redirected
/// to a per-test file, so tests never touch the real host's /etc/hyper.
pub fn run(config: &Path, args: &[&str]) -> Output {
    let mut cmd = Command::new(BIN);
    cmd.args(args)
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config);
    if let Some(profile) = std::env::var_os("LLVM_PROFILE_FILE") {
        cmd.env("LLVM_PROFILE_FILE", profile);
    }
    cmd.output().expect("spawn helper")
}
