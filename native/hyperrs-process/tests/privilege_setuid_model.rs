//! The privilege API under the credentials a setuid-root exec really produces: real ids are the
//! caller's, effective and saved uid are 0, and the kernel marks the exec `AT_SECURE`.
//!
//! A root parent cannot fake that inside its own process, so each `*_as_root` test re-execs this
//! test binary into one ignored `child_*` scenario with `setresuid(caller, 0, 0)` and the
//! caller's gids. The child then sits exactly where a freshly exec'd setuid helper sits.
//!
//! Laws:
//! - the pre-main drop refuses a dynamically linked setuid exec before any Rust code runs;
//! - `take` refuses while euid or egid differs from the real ids, and a refused `take` does not
//!   spend the one token;
//! - `elevate` raises euid and egid to 0 and nothing else; dropping the guard restores exactly the
//!   caller's ids, keeps saved uid 0, and the cycle repeats;
//! - a child spawned with `spawn_as_root` is genuine root (all uids and gids 0, groups `[0]`) with
//!   none of the caller's environment, while the spawning process keeps the caller's real ids;
//! - a failed `elevate` leaves the process unprivileged, never half-raised.

use hyperrs_process::privilege::{
    drop_to_real, PrivilegeError, RootCommandExt, TakeError, Unprivileged,
};
use nix::libc;
use nix::unistd::{
    getegid, geteuid, getgid, getgroups, getresuid, getuid, setegid, seteuid, setgroups, setresgid,
    setresuid, Gid, Uid,
};
use pretty_assertions::assert_eq;
use rstest::rstest;
use std::os::unix::process::CommandExt;
use std::process::{Command, Output};

const SCENARIO: &str = "HYPERRS_SETUID_MODEL_SCENARIO";
const CALLER_UID: u32 = 65_534;
const CALLER_GID: u32 = 65_534;
const CALLER_GROUPS: [u32; 2] = [65_534, 4_242];
const CAP_SETGID: libc::c_ulong = 6;

fn in_scenario(name: &str) -> bool {
    std::env::var(SCENARIO).as_deref() == Ok(name)
}

fn exec_setuid_child(scenario: &str, drop_setgid_cap: bool) -> Output {
    let mut cmd = Command::new(std::env::current_exe().unwrap());
    cmd.args([
        scenario,
        "--exact",
        "--ignored",
        "--nocapture",
        "--test-threads=1",
    ])
    .env_clear()
    .env(SCENARIO, scenario)
    .env("CALLER_SECRET", "leaked")
    .current_dir("/");
    // SAFETY: the hook runs in the forked child before exec and only makes id and prctl syscalls.
    unsafe {
        cmd.pre_exec(move || {
            let groups: Vec<Gid> = CALLER_GROUPS.iter().copied().map(Gid::from_raw).collect();
            setgroups(&groups)?;
            let gid = Gid::from_raw(CALLER_GID);
            setresgid(gid, gid, gid)?;
            if drop_setgid_cap && libc::prctl(libc::PR_CAPBSET_DROP, CAP_SETGID, 0, 0, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
            setresuid(
                Uid::from_raw(CALLER_UID),
                Uid::from_raw(0),
                Uid::from_raw(0),
            )?;
            Ok(())
        });
    }
    cmd.output().unwrap()
}

fn describe(out: &Output) -> String {
    format!(
        "status {:?}\nstdout:\n{}\nstderr:\n{}",
        out.status,
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    )
}

fn mirror_the_pre_main_drop() {
    setegid(getgid()).unwrap();
    seteuid(getuid()).unwrap();
}

fn status_ids(status: &str, key: &str) -> Vec<u32> {
    status
        .lines()
        .find_map(|line| line.strip_prefix(key))
        .unwrap_or_else(|| panic!("no {key} in {status}"))
        .split_whitespace()
        .map(|n| n.parse().unwrap())
        .collect()
}

#[rstest]
#[case::the_pre_main_drop_refuses_a_dynamic_setuid_exec("child_drop_to_real", false, Some(1))]
#[case::elevate_and_drop_restore_the_caller_exactly("child_elevate_cycle", false, Some(0))]
#[case::a_spawned_root_child_is_genuine_root_with_no_caller_env(
    "child_spawn_as_root",
    false,
    Some(0)
)]
#[case::a_failed_elevate_leaves_the_process_unprivileged("child_failed_elevate", true, Some(0))]
fn setuid_exec_model_as_root(
    #[case] scenario: &str,
    #[case] drop_setgid_cap: bool,
    #[case] code: Option<i32>,
) {
    if !geteuid().is_root() {
        eprintln!("SKIP setuid model: needs root to exec a child with setuid credentials");
        return;
    }
    let out = exec_setuid_child(scenario, drop_setgid_cap);
    assert_eq!(out.status.code(), code, "{}", describe(&out));
    if scenario == "child_drop_to_real" {
        assert!(
            String::from_utf8_lossy(&out.stderr)
                .contains("refusing to run setuid as a dynamically linked binary"),
            "{}",
            describe(&out)
        );
    } else {
        assert!(
            String::from_utf8_lossy(&out.stdout).contains("1 passed"),
            "the scenario did not run: {}",
            describe(&out)
        );
    }
}

#[test]
#[ignore = "re-exec'd with setuid credentials by setuid_exec_model_as_root"]
fn child_drop_to_real() {
    if !in_scenario("child_drop_to_real") {
        return;
    }
    drop_to_real();
    panic!("drop_to_real returned in a dynamically linked AT_SECURE exec");
}

#[test]
#[ignore = "re-exec'd with setuid credentials by setuid_exec_model_as_root"]
fn child_elevate_cycle() {
    if !in_scenario("child_elevate_cycle") {
        return;
    }
    let caller = (Uid::from_raw(CALLER_UID), Gid::from_raw(CALLER_GID));
    assert_eq!(
        getresuid().unwrap().effective,
        Uid::from_raw(0),
        "simulation"
    );
    assert!(matches!(
        Unprivileged::take(),
        Err(TakeError::StillPrivileged { euid, egid }) if euid.is_root() && egid == caller.1
    ));

    mirror_the_pre_main_drop();
    let groups = getgroups().unwrap();
    let mut token = Unprivileged::take().expect("a refused take must not spend the token");

    for round in 0..3 {
        let root = token.elevate().unwrap();
        assert_eq!(
            (geteuid(), getegid()),
            (Uid::from_raw(0), Gid::from_raw(0)),
            "round {round}"
        );
        assert_eq!((getuid(), getgid()), caller, "round {round}");
        assert_eq!(getgroups().unwrap(), groups, "round {round}");
        drop(root);
        assert_eq!((geteuid(), getegid()), caller, "round {round}");
        assert_eq!((getuid(), getgid()), caller, "round {round}");
        assert_eq!(
            getresuid().unwrap().saved,
            Uid::from_raw(0),
            "round {round}"
        );
        assert_eq!(getgroups().unwrap(), groups, "round {round}");
    }
}

#[test]
#[ignore = "re-exec'd with setuid credentials by setuid_exec_model_as_root"]
fn child_spawn_as_root() {
    if !in_scenario("child_spawn_as_root") {
        return;
    }
    mirror_the_pre_main_drop();
    let mut token = Unprivileged::take().unwrap();
    let root = token.elevate().unwrap();

    let status = Command::new("/bin/cat")
        .arg("/proc/self/status")
        .spawn_as_root(&root, &[])
        .output()
        .unwrap();
    let env = Command::new("/usr/bin/env")
        .spawn_as_root(&root, &[])
        .output()
        .unwrap();

    assert_eq!(
        (getuid(), getgid()),
        (Uid::from_raw(CALLER_UID), Gid::from_raw(CALLER_GID))
    );
    drop(root);
    let status = String::from_utf8(status.stdout).unwrap();
    assert_eq!(status_ids(&status, "Uid:"), [0, 0, 0, 0]);
    assert_eq!(status_ids(&status, "Gid:"), [0, 0, 0, 0]);
    assert_eq!(status_ids(&status, "Groups:"), [0]);
    assert_eq!(
        String::from_utf8_lossy(&env.stdout),
        "",
        "caller env reached root"
    );
}

#[test]
#[ignore = "re-exec'd with setuid credentials by setuid_exec_model_as_root"]
fn child_failed_elevate() {
    if !in_scenario("child_failed_elevate") {
        return;
    }
    mirror_the_pre_main_drop();
    let mut token = Unprivileged::take().unwrap();

    let raised = token.elevate();

    assert!(
        matches!(raised, Err(PrivilegeError::RaiseGroup(_))),
        "without CAP_SETGID the egid raise must fail: {raised:?}"
    );
    drop(raised);
    assert_eq!(
        (geteuid(), getegid()),
        (Uid::from_raw(CALLER_UID), Gid::from_raw(CALLER_GID)),
        "elevate failed but left the process with root ids"
    );
}
