//! Checksum stamping: the post-link step cargo has no native hook for.
//!
//! BLAKE3-hashes the release ELF with the `.note.sum` section zeroed, then
//! writes that digest back into the section. The binary reports it via
//! `hyper-suidhelper version`; a verifier re-zeroes the section, rehashes, and
//! compares.

use std::path::{Path, PathBuf};

use object::elf::PT_INTERP;
use object::read::elf::ProgramHeader;

use crate::{target_dir, BIN};

/// Build the release binary and stamp its checksum section. Returns the path to
/// the stamped ELF.
pub fn run() -> PathBuf {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let target = format!("{}-unknown-linux-musl", std::env::consts::ARCH);
    require_target(&target);
    let mut build = std::process::Command::new(cargo);
    build.args(["build", "--release", "--target", &target, "-p", BIN]);
    // CI coverage seam: instrument ONLY the helper build. A job-wide RUSTFLAGS
    // would also instrument the guest agent, which runs as PID 1 inside the
    // guest where no profile can be collected. Appending (not replacing)
    // preserves any caller-provided RUSTFLAGS.
    if std::env::var("HYPER_SUIDHELPER_INSTRUMENT_COVERAGE").as_deref() == Ok("1") {
        let mut flags = std::env::var("RUSTFLAGS").unwrap_or_default();
        if !flags.is_empty() {
            flags.push(' ');
        }
        // runtime-counter-relocation enables LLVM continuous mode (`%c` in
        // LLVM_PROFILE_FILE): counters are mmap-written as they increment, so
        // profiles survive the jailer's execve/_exit paths, which never reach
        // the normal atexit dump.
        flags.push_str("-C instrument-coverage -C llvm-args=-runtime-counter-relocation");
        build.env("RUSTFLAGS", flags);
    }
    let status = build.status().expect("failed to spawn cargo");
    assert!(status.success(), "cargo build --release failed");

    let built = target_dir().join(&target).join("release").join(BIN);
    let mut bytes = std::fs::read(&built).expect("failed to read release binary");
    assert!(
        !has_interpreter(&bytes),
        "{} is dynamically linked; the setuid helper must be static",
        built.display()
    );

    hyperrs_elfsum::Elf::parse(&mut bytes[..])
        .unwrap_or_else(|err| panic!("cannot stamp {}: {err}", built.display()))
        .stamp();

    let path = target_dir().join(BIN);
    std::fs::copy(&built, &path).expect("failed to copy release binary");
    std::fs::write(&path, &bytes).expect("failed to write stamped binary");
    path
}

fn require_target(target: &str) {
    let crate_dir = target_dir()
        .parent()
        .expect("target dir has no parent")
        .to_path_buf();
    let out = std::process::Command::new("rustc")
        .args(["--print", "target-libdir", "--target", target])
        .current_dir(&crate_dir)
        .output()
        .expect("failed to spawn rustc");
    let libdir = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success() && Path::new(libdir.trim()).is_dir(),
        "the {target} target is not installed for the helper's toolchain; run \
         `rustup target add {target}` in {}",
        crate_dir.display()
    );
}

fn has_interpreter(bytes: &[u8]) -> bool {
    let object::File::Elf64(elf) = object::File::parse(bytes).expect("failed to parse ELF") else {
        panic!("expected a 64-bit ELF");
    };
    elf.elf_program_headers()
        .iter()
        .any(|header| header.p_type(elf.endian()) == PT_INTERP)
}
