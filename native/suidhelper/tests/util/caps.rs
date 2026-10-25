//! Contract of the capability-narrowing privilege guard
//! (`hyper_suidhelper::util::caps`, `setuid_privileged::Privileged`).
//!
//! Laws under test, each judged against the kernel's own report in
//! `/proc/.../status` (an oracle independent of the `capget` the code uses):
//! - **Mask is exact in-process:** for every mask `m`, inside
//!   `Privileged::acquire(m)` the effective set is exactly `m`, and after the
//!   guard drops it is empty.
//! - **Mask is exact across exec:** for every mask `m`, a child spawned through
//!   the guard (`command` and `root_command` alike) execs with effective,
//!   permitted and bounding sets exactly `m`, and empty inheritable and ambient
//!   sets — even though uid-0 exec would otherwise grant the full bounding set.
//! - **Refusal:** an operation needing a capability outside the mask fails with
//!   `EPERM`; the same operation succeeds once the mask includes it.
//!
//! All root-gated (`_as_root`), run by CI's privileged job. Capabilities are
//! per-thread and each test runs on its own thread, so the in-process checks
//! read `/proc/thread-self`.

use hyper_suidhelper::util::caps::Caps;
use hyper_suidhelper::util::setuid_privileged::Privileged;
use nix::errno::Errno;
use nix::sys::stat::{mknod, Mode, SFlag};
use proptest::prelude::*;
use std::fs;
use std::process::Command;

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

/// Every capability this kernel knows, as a mask.
fn all_caps() -> u64 {
    let last: u32 = fs::read_to_string("/proc/sys/kernel/cap_last_cap")
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    (1u64 << (last + 1)) - 1
}

fn mask() -> impl Strategy<Value = Caps> {
    any::<u64>().prop_map(|bits| Caps::from_bits(bits & all_caps()))
}

/// The hex `Cap<field>:` line of a `/proc/<pid>/status` dump.
fn cap_field(status: &str, field: &str) -> u64 {
    let prefix = format!("Cap{field}:");
    let line = status
        .lines()
        .find_map(|l| l.strip_prefix(&prefix))
        .unwrap_or_else(|| panic!("no Cap{field} in status"));
    u64::from_str_radix(line.trim(), 16).unwrap()
}

fn own_effective() -> u64 {
    cap_field(
        &fs::read_to_string("/proc/thread-self/status").unwrap(),
        "Eff",
    )
}

fn child_status(cmd: &mut Command) -> String {
    let out = cmd.arg("/proc/self/status").output().expect("spawn cat");
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]

    #[test]
    fn effective_set_is_exactly_the_mask_then_empty_as_root(m in mask()) {
        if !is_root() {
            return Ok(());
        }
        {
            let _guard = Privileged::acquire(m).unwrap();
            prop_assert_eq!(own_effective(), m.bits());
        }
        prop_assert_eq!(own_effective(), 0);
    }

    #[test]
    fn child_execs_with_exactly_the_mask_as_root(m in mask()) {
        if !is_root() {
            return Ok(());
        }
        let guard = Privileged::acquire(m).unwrap();
        let spawners: [fn(&Privileged) -> Command; 2] = [
            |g| g.command("/bin/cat"),
            |g| g.root_command("/bin/cat"),
        ];
        for spawn in spawners {
            let status = child_status(&mut spawn(&guard));
            for field in ["Eff", "Prm", "Bnd"] {
                prop_assert_eq!(cap_field(&status, field), m.bits(), "Cap{}", field);
            }
            for field in ["Inh", "Amb"] {
                prop_assert_eq!(cap_field(&status, field), 0, "Cap{}", field);
            }
        }
    }
}

#[test]
fn capability_outside_the_mask_is_refused_as_root() {
    if !is_root() {
        eprintln!("SKIP capability refusal: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let node = tmp.path().join("null");
    let make = || {
        mknod(
            &node,
            SFlag::S_IFCHR,
            Mode::from_bits_truncate(0o600),
            nix::sys::stat::makedev(1, 3),
        )
    };

    let everything_but_mknod = Caps::from_bits(all_caps() & !Caps::MKNOD.bits());
    {
        let _guard = Privileged::acquire(everything_but_mknod).unwrap();
        assert_eq!(make(), Err(Errno::EPERM));
    }
    {
        let _guard = Privileged::acquire(Caps::MKNOD).unwrap();
        make().expect("mknod with CAP_MKNOD");
    }
}

#[test]
fn child_is_refused_a_capability_outside_the_mask_as_root() {
    if !is_root() {
        eprintln!("SKIP child capability refusal: needs root");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let node = tmp.path().join("null");
    let mknod_in_child = |caps: Caps| {
        let guard = Privileged::acquire(caps).unwrap();
        guard
            .command("/usr/bin/mknod")
            .arg(&node)
            .args(["c", "1", "3"])
            .output()
            .unwrap()
            .status
            .success()
    };

    assert!(
        !mknod_in_child(Caps::empty()),
        "mknod must fail without CAP_MKNOD"
    );
    assert!(
        mknod_in_child(Caps::MKNOD),
        "mknod must succeed with CAP_MKNOD"
    );
}
