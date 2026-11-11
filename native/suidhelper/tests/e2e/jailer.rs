//! L4 for the jailer handoff: prove the exact argv (and an EMPTY environment) the
//! helper hands to the jailer via `execve`, and that the jailer's exit status
//! propagates. We point the config's `jailer` at a root-owned recorder that
//! writes its argv and its `/proc/self/environ` to files, then exits with a known
//! code. Root-only: `become_root_permanently` requires we are already root.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use predicates::str::contains;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

mod support;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{OpenFlags, SafeFile};
use hyperrs_fs::lock::FileLock;
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use hyperrs_linux::net::netns::NetNs;
use hyperrs_linux::net::{IfName, Rtnl};
use std::os::unix::fs::DirBuilderExt;
use std::process::Stdio;
use std::thread;
use std::time::Duration;
use support::{is_root, MapperDevice, ScratchNs, NET_TABLE};

const RECORDER_EXIT: i32 = 7;

static LAUNCHES: AtomicU32 = AtomicU32::new(0);

fn install(dir: &Path, name: &str, body: &str, mode: u32) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, body).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
    path
}

struct Launch {
    id: String,
    ns: ScratchNs,
    tmp: TempDir,
    work: PathBuf,
    jail: PathBuf,
    firecracker: PathBuf,
    jailer: PathBuf,
    kernel: PathBuf,
    rootfs: MapperDevice,
}

impl Drop for Launch {
    fn drop(&mut self) {
        let _ = NetNs::delete(self.netns().as_str().try_into().unwrap());
    }
}

impl Launch {
    fn config(&self, tables: &str) -> PathBuf {
        let p = self.tmp.path().join("config.toml");
        let body = format!(
            "work_dir = \"{}\"\n[tools]\njailer = \"{}\"\nfirecracker = \"{}\"\n{tables}{NET_TABLE}",
            self.work.display(),
            self.jailer.display(),
            self.firecracker.display(),
        );
        fs::write(&p, body).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o644)).unwrap();
        p
    }

    fn request(&self, overrides: Value) -> Value {
        let mut request = json!({
            "op": "vm_launch",
            "id": self.id,
            "uid": 900_001,
            "gid": 900_002,
            "kernel": self.kernel,
            "device": self.rootfs.path(),
            "limits": {},
            "net_id": 0,
            "firewall": {"inbound": [], "outbound_blocked": []},
        });
        request
            .as_object_mut()
            .unwrap()
            .extend(overrides.as_object().unwrap().clone());
        request
    }

    fn root(&self) -> PathBuf {
        self.jail.join(format!("firecracker/{}/root", self.id))
    }

    fn plant_stale_jail(&self) -> PathBuf {
        let stale = self.root().join("stale");
        fs::create_dir_all(stale.parent().unwrap()).unwrap();
        fs::write(&stale, b"left by a previous incarnation").unwrap();
        stale
    }

    fn netns(&self) -> String {
        format!("hyper-{}", self.id)
    }

    fn run(&self, cfg: &Path, request: Value) -> assert_cmd::assert::Assert {
        self.ns.run(cfg, request)
    }

    fn recorded_argv(&self) -> Option<Vec<String>> {
        let body = fs::read_to_string(self.tmp.path().join("argv.json")).ok()?;
        Some(serde_json::from_str(&body).unwrap())
    }

    fn recorded_environ(&self) -> Vec<u8> {
        fs::read(self.tmp.path().join("environ.bin")).expect("recorded environ")
    }
}

#[fixture]
fn launch() -> Option<Launch> {
    let tmp = TempDir::new().unwrap();
    let base = fs::canonicalize(tmp.path()).unwrap();
    let work = base.join("srv");
    let jail = work.join("jails");
    fs::create_dir_all(&jail).unwrap();
    let firecracker = install(&base, "firecracker", "#!/bin/true\n", 0o644);
    let jailer = base.join("jailer");
    fs::copy(env!("CARGO_BIN_EXE_fake-jailer"), &jailer).unwrap();
    fs::set_permissions(&jailer, fs::Permissions::from_mode(0o755)).unwrap();
    let kernel = install(&work, "vmlinux-src", "kernel image", 0o644);
    let backing = base.join("rootfs.img");
    fs::write(&backing, vec![0u8; 1024 * 1024]).unwrap();
    let rootfs = MapperDevice::linear(
        &format!("hyper-e2e-launch-{}", std::process::id()),
        &backing,
    )?;
    if !is_root() {
        return None;
    }
    let id = format!(
        "vm{}x{}",
        std::process::id(),
        LAUNCHES.fetch_add(1, Ordering::Relaxed)
    );
    Some(Launch {
        ns: ScratchNs::new(&id),
        id,
        tmp,
        work,
        jail,
        firecracker,
        jailer,
        kernel,
        rootfs,
    })
}

macro_rules! require {
    ($launch:expr) => {
        match (is_root(), $launch) {
            (true, Some(launch)) => launch,
            _ => {
                eprintln!("SKIP: needs root and losetup/dmsetup");
                return;
            }
        }
    };
}

#[rstest]
fn launch_clears_the_stale_jail_stages_the_boot_artifacts_then_execs_as_root(
    launch: Option<Launch>,
) {
    let launch = require!(launch);
    let cfg = launch.config("");
    let stale = launch.plant_stale_jail();

    launch
        .run(&cfg, launch.request(json!({})))
        .code(RECORDER_EXIT);

    assert!(
        !stale.exists(),
        "the stale jail must be cleared before staging"
    );
    let root = launch.root();
    assert_eq!(fs::read(root.join("vmlinux")).unwrap(), b"kernel image");
    let rootfs = fs::metadata(root.join("rootfs")).unwrap();
    assert_eq!(
        rootfs.rdev(),
        fs::metadata(launch.rootfs.path()).unwrap().rdev()
    );
    assert_eq!((rootfs.uid(), rootfs.gid()), (900_001, 900_002));
    assert!(
        !root.join("dev/net/tun").exists(),
        "the jailer mknods dev/net/tun itself and fails on EEXIST"
    );
}

#[rstest]
fn execs_jailer_with_canonical_argv_and_empty_env_as_root(launch: Option<Launch>) {
    let launch = require!(launch);
    let cfg = launch.config("");

    launch
        .run(
            &cfg,
            launch.request(json!({
                "limits": {
                    "memory_max": 1_048_576,
                    "cpu_max": {"quota_us": 100_000, "period_us": 100_000},
                },
            })),
        )
        .code(RECORDER_EXIT);

    let jail = launch.jail.display().to_string();
    let firecracker = launch.firecracker.display().to_string();
    assert_eq!(
        launch.recorded_argv().expect("the jailer was exec'd"),
        [
            "--id",
            &launch.id,
            "--exec-file",
            &firecracker,
            "--uid",
            "900001",
            "--gid",
            "900002",
            "--chroot-base-dir",
            &jail,
            "--cgroup-version",
            "2",
            "--parent-cgroup",
            "hyper",
            "--netns",
            &format!("/run/netns/{}", launch.netns()),
            "--cgroup",
            "memory.max=1048576",
            "--cgroup",
            "cpu.max=100000 100000",
            "--",
            "--api-sock",
            "/api.socket",
        ],
        "helper handed the jailer a non-canonical argv",
    );

    // The helper execve's the jailer with an EMPTY envp (see src/cli/vm/launch.rs):
    // once ruid==0 a smuggled LD_PRELOAD would be honored, so nothing of the
    // caller's environment may reach the root jailer. The recorder is a `/bin/sh`
    // script and the shell *self-sets* `PWD` (and, under bash, `_`/`SHLVL`) on
    // startup, so a literally-empty environ is impossible to observe through it.
    // We instead prove no CALLER variable survives: the helper is spawned with
    // `HYPER_*` config vars in its own environment (see `run`), so their absence
    // here is the leak canary - had the helper passed its environment through,
    // they would appear alongside `PWD`.
    let leaked: Vec<String> = launch
        .recorded_environ()
        .split(|&b| b == 0)
        .filter(|entry| !entry.is_empty())
        .map(|entry| String::from_utf8_lossy(entry).into_owned())
        .filter(|entry| {
            let key = entry.split('=').next().unwrap_or("");
            !matches!(key, "PWD" | "_" | "SHLVL")
        })
        .collect();
    assert!(
        leaked.is_empty(),
        "caller environment leaked to the jailer (only shell-set PWD/_/SHLVL allowed): {leaked:?}",
    );
}

#[rstest]
#[case::root_uid(json!({"uid": 0}), "outside the configured range")]
#[case::root_gid(json!({"gid": 0}), "outside the configured range")]
#[case::uid_below_range(json!({"uid": 1000}), "outside the configured range")]
#[case::gid_above_range(json!({"gid": 1_000_000}), "outside the configured range")]
#[case::absent_kernel(json!({"kernel": "/srv/hyper-e2e-absent/vmlinux"}), "kernel")]
#[case::system_rootfs(json!({"device": "/dev/sda"}), "invalid request")]
fn refused_launches_touch_nothing_and_never_exec_as_root(
    launch: Option<Launch>,
    #[case] overrides: Value,
    #[case] stderr: &str,
) {
    let launch = require!(launch);
    let cfg = launch.config("");
    let stale = launch.plant_stale_jail();

    launch
        .run(&cfg, launch.request(overrides))
        .code(2)
        .stderr(contains(stderr));

    assert!(
        launch.recorded_argv().is_none(),
        "the jailer must never run"
    );
    assert!(
        stale.exists(),
        "a refused launch must not tear anything down"
    );
    assert!(
        !launch.root().join("vmlinux").exists(),
        "nothing may be staged"
    );
}

#[rstest]
fn launch_networks_the_vm_and_teardown_removes_it_as_root(launch: Option<Launch>) {
    let launch = require!(launch);
    let cfg = launch.config("");
    let name = |s: &str| -> IfName { s.parse().unwrap() };
    let links = |rtnl: &Rtnl, names: &[&str]| -> Vec<bool> {
        names
            .iter()
            .map(|n| rtnl.link(&name(n)).unwrap().is_some())
            .collect()
    };
    let host_veth = || {
        launch
            .ns
            .get()
            .scoped(|| links(&Rtnl::open().unwrap(), &["vm-veth-0"]))
            .unwrap()
    };

    launch
        .run(&cfg, launch.request(json!({})))
        .code(RECORDER_EXIT);

    let vm_ns = NetNs::open(launch.netns().as_str().try_into().unwrap()).unwrap();
    assert_eq!(
        (
            host_veth(),
            links(&vm_ns.rtnl().unwrap(), &["uplink", "tap0", "vm-veth-0"]),
        ),
        (vec![true], vec![true, true, false])
    );
    drop(vm_ns);

    launch
        .run(
            &cfg,
            json!({"op": "vm_firewall", "id": launch.id, "firewall": {
                "inbound": [{"protocol": "tcp", "ports": [22, 22]}], "outbound_blocked": []}}),
        )
        .success()
        .stdout(contains("firewall_set"));

    launch
        .run(&cfg, json!({"op": "vm_teardown", "id": launch.id}))
        .success();

    assert_eq!(host_veth(), vec![false]);
    assert!(NetNs::open(launch.netns().as_str().try_into().unwrap()).is_err());
    launch
        .run(
            &cfg,
            json!({"op": "vm_firewall", "id": launch.id, "firewall": {
                "inbound": [], "outbound_blocked": []}}),
        )
        .code(2)
        .stderr(contains("has no network namespace"));
}

#[rstest]
fn teardown_waits_for_the_vm_lock_an_in_flight_launch_holds_as_root(launch: Option<Launch>) {
    let launch = require!(launch);
    let cfg = launch.config("");
    let locks = PathBuf::from("/run/hyper/locks");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&locks)
        .unwrap();
    fs::set_permissions("/run/hyper", fs::Permissions::from_mode(0o755)).unwrap();
    let locks_path: SafePathBuf<IsAbsolute, StrictComponents> = locks.clone().try_into().unwrap();
    let dir: SafeDir = SafeFile::open(&locks_path, OpenFlags::RDONLY).unwrap();
    let name = format!("vm-{}", launch.id);
    let held = FileLock::acquire(
        &dir,
        name.as_str().try_into().unwrap(),
        Duration::from_secs(5),
    )
    .unwrap();

    let request = json!({"op": "vm_teardown", "id": launch.id}).to_string();
    let mut teardown = launch
        .ns
        .get()
        .scoped(|| {
            support::command(&cfg, &[&request])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .unwrap();
    thread::sleep(Duration::from_millis(500));
    let waited = teardown.try_wait().unwrap().is_none();
    drop(held);
    let out = teardown.wait_with_output().unwrap();

    assert_eq!(
        (
            waited,
            out.status.success(),
            String::from_utf8_lossy(&out.stdout).contains("tore_down"),
            locks.join(&name).exists(),
        ),
        (true, true, true, false),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
