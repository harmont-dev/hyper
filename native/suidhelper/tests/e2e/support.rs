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

use assert_cmd::assert::Assert;
use assert_cmd::Command;
use std::fs;
use std::path::Path;
use std::process::Command as Process;

pub const BIN: &str = env!("CARGO_BIN_EXE_hyper-suidhelper");

pub fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

/// Run the helper with insecure mode open and the config path redirected
/// to a per-test file, so tests never touch the real host's /etc/hyper.
pub fn run(config: &Path, request: serde_json::Value) -> Assert {
    run_args(config, &[&request.to_string()])
}

pub fn run_args(config: &Path, args: &[&str]) -> Assert {
    let mut cmd = Command::new(BIN);
    cmd.args(args)
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config);
    if let Ok(profile) = std::env::var("LLVM_PROFILE_FILE") {
        cmd.env("LLVM_PROFILE_FILE", profile);
    }
    cmd.assert()
}

pub fn stdout_json(assert: &Assert) -> serde_json::Value {
    serde_json::from_slice(&assert.get_output().stdout).expect("stdout is JSON")
}

pub struct LoopDevice(String);

impl LoopDevice {
    pub fn attach(backing: &Path) -> Option<Self> {
        let out = Process::new("losetup")
            .args(["--find", "--show"])
            .arg(backing)
            .output()
            .ok()
            .filter(|out| out.status.success())?;
        Some(Self(String::from_utf8(out.stdout).ok()?.trim().to_string()))
    }
}

impl Drop for LoopDevice {
    fn drop(&mut self) {
        let _ = Process::new("losetup").args(["--detach", &self.0]).status();
    }
}

pub struct MapperDevice {
    name: String,
    _loop_dev: LoopDevice,
}

impl MapperDevice {
    pub fn linear(name: &str, backing: &Path) -> Option<Self> {
        let loop_dev = LoopDevice::attach(backing)?;
        let sectors = fs::metadata(backing).unwrap().len() / 512;
        let table = format!("0 {sectors} linear {} 0", loop_dev.0);
        Process::new("dmsetup")
            .args(["create", name, "--table", &table])
            .status()
            .is_ok_and(|status| status.success())
            .then(|| Self {
                name: name.to_string(),
                _loop_dev: loop_dev,
            })
    }

    pub fn path(&self) -> String {
        format!("/dev/mapper/{}", self.name)
    }
}

impl Drop for MapperDevice {
    fn drop(&mut self) {
        let _ = Process::new("dmsetup")
            .args(["remove", "--retry", &self.name])
            .status();
    }
}
