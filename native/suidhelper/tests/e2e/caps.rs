//! L4: every tool's child binary execs holding exactly that tool's declared
//! capability mask — never the full root set a uid-0 exec would otherwise get.
//! `tests/util/caps.rs` proves the mechanism for arbitrary masks; this proves
//! each subcommand is actually wired through it (spawning via the guard, or for
//! the jailer, confining before `execve`). Each row points the tool's config path
//! at a root-owned fake that dumps its own `/proc/self/status`.
#![cfg(feature = "insecure_test_seams")]

use hyper_suidhelper::tools::{Blockdev, Dmsetup, IsTool, Losetup, ThinDump};
use hyper_suidhelper::util::caps::Caps;
use std::fs;
use std::os::unix::fs::PermissionsExt;

mod support;
use support::{is_root, run};

fn cap_field(status: &str, field: &str) -> u64 {
    let prefix = format!("Cap{field}:");
    let line = status
        .lines()
        .find_map(|l| l.strip_prefix(&prefix))
        .unwrap_or_else(|| panic!("no Cap{field} in status"));
    u64::from_str_radix(line.trim(), 16).unwrap()
}

struct Row {
    /// Config `[tools]` key, which is also the fake's basename.
    tool: &'static str,
    args: &'static [&'static str],
    caps: Caps,
}

#[test]
fn each_tool_child_holds_exactly_its_declared_caps_as_root() {
    if !is_root() {
        eprintln!("SKIP per-tool child caps: needs root to own the fakes");
        return;
    }
    let rows = [
        Row {
            tool: "losetup",
            args: &["losetup", "list"],
            caps: Losetup::CAPS,
        },
        Row {
            tool: "dmsetup",
            args: &["dmsetup", "ls"],
            caps: Dmsetup::CAPS,
        },
        Row {
            tool: "blockdev",
            args: &["blockdev", "--getsz", "/dev/loop0"],
            caps: Blockdev::CAPS,
        },
        Row {
            tool: "thin_dump",
            args: &["thin-dump", "--meta", "/dev/loop0", "--dev-id", "1"],
            caps: ThinDump::CAPS,
        },
        Row {
            tool: "jailer",
            args: &[
                "jailer",
                "--id",
                "vm1",
                "--uid",
                "900001",
                "--gid",
                "900002",
                "--api-sock",
                "/api.sock",
            ],
            caps: hyper_suidhelper::util::jailer::CAPS,
        },
    ];

    for row in rows {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();
        let record = dir.join("status");
        let fake = dir.join(row.tool);
        fs::write(
            &fake,
            format!(
                "#!/bin/sh\n/bin/cat /proc/self/status > '{}'\n",
                record.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        // The jailer's `--exec-file`: validated as a root-owned file, never run.
        let firecracker = dir.join("firecracker");
        fs::write(&firecracker, b"").unwrap();

        let cfg = dir.join("config.toml");
        fs::write(
            &cfg,
            format!(
                "work_dir = \"/srv/hyper\"\n[tools]\n{} = \"{}\"\nfirecracker = \"{}\"\n",
                row.tool,
                fake.display(),
                firecracker.display(),
            ),
        )
        .unwrap();

        // The fakes print nothing parseable, so the helper's own result is
        // irrelevant here; only what the child held matters.
        let out = run(&cfg, row.args);
        let status = fs::read_to_string(&record).unwrap_or_else(|_| {
            panic!(
                "{}: fake never ran; stderr: {}",
                row.tool,
                String::from_utf8_lossy(&out.stderr)
            )
        });
        for field in ["Eff", "Prm", "Bnd"] {
            assert_eq!(
                cap_field(&status, field),
                row.caps.bits(),
                "{}: Cap{field}",
                row.tool
            );
        }
    }
}
