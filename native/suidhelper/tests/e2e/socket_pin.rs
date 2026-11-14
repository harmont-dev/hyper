//! The socket-pin contract of #135, observed through the binary: `vm_claim_*_socket` hard-links
//! the VM's own socket into `<work_dir>/socks/fc-<id>-<socket>`, and `vm_teardown` removes exactly
//! that VM's pins under the VM's lock.
//!
//! Laws:
//! - claim is idempotent: re-claiming leaves one pin, still the jail socket's inode, `0600` and
//!   owned by the caller;
//! - claim never follows what already sits at the pin name: a planted symlink is replaced, its
//!   target untouched;
//! - claim refuses anything at the jail socket name that is not a socket, and then pins nothing;
//! - teardown is scoped: tearing down VM `a` removes `a`'s two pins and jail and nothing else in
//!   the socket dir, even for a VM `b` whose id has `a` as a dash-separated prefix;
//! - teardown is idempotent and leaves no lock file behind, and concurrent teardowns of one VM all
//!   succeed (they serialize on the lock rather than time out or trip over each other).
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use proptest::prelude::*;
use rstest::rstest;
use serde_json::json;
use std::fs;
use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Stdio;

mod support;
use support::{is_root, run, stdout_json};

const SOCKETS: [(&str, &str); 2] = [
    ("vm_claim_api_socket", "api.socket"),
    ("vm_claim_vsock_socket", "vsock.sock"),
];

const LOCKS: &str = "/run/hyper-suidhelper/locks";

struct Work {
    tmp: TempDir,
    srv: PathBuf,
    config: PathBuf,
    listeners: Vec<UnixListener>,
}

impl Work {
    fn new() -> Self {
        let tmp = TempDir::new().unwrap();
        let srv = tmp.path().join("srv");
        fs::create_dir_all(srv.join("socks")).unwrap();
        let config = tmp.path().join("config.toml");
        fs::write(
            &config,
            format!(
                "work_dir = \"{}\"\n[jails]\ncgroup = \"hyper-e2e-does-not-exist\"\n",
                srv.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o644)).unwrap();
        Self {
            tmp,
            srv,
            config,
            listeners: Vec::new(),
        }
    }

    fn jail(&self, id: &str) -> PathBuf {
        let root = self.srv.join("jails/firecracker").join(id).join("root");
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn socks(&self) -> PathBuf {
        self.srv.join("socks")
    }

    fn pin(&self, id: &str, socket: &str) -> PathBuf {
        self.socks().join(format!("fc-{id}-{socket}"))
    }

    fn boot(&mut self, id: &str) {
        let jail = self.jail(id);
        for (_, socket) in SOCKETS {
            self.listeners
                .push(UnixListener::bind(jail.join(socket)).unwrap());
        }
    }

    fn claim_all(&self, id: &str) {
        for (op, _) in SOCKETS {
            let out = run(&self.config, json!({"op": op, "id": id})).success();
            assert_eq!(stdout_json(&out)["result"], "claimed", "{op} {id}");
        }
    }

    fn teardown(&self, id: &str) {
        let out = run(&self.config, json!({"op": "vm_teardown", "id": id})).success();
        assert_eq!(stdout_json(&out)["result"], "tore_down");
    }
}

fn unique(tag: &str) -> String {
    format!("{tag}{}", std::process::id())
}

fn ino(path: &Path) -> (u64, u64) {
    let meta = fs::symlink_metadata(path).unwrap();
    (meta.dev(), meta.ino())
}

#[rstest]
#[case::api(SOCKETS[0])]
#[case::vsock(SOCKETS[1])]
fn reclaiming_keeps_one_private_pin_on_the_jail_socket_as_root(#[case] (op, socket): (&str, &str)) {
    if !is_root() {
        eprintln!("SKIP claim idempotence: needs root");
        return;
    }
    let mut work = Work::new();
    let id = unique("idem");
    work.boot(&id);

    for _ in 0..3 {
        let out = run(&work.config, json!({"op": op, "id": id})).success();
        assert_eq!(stdout_json(&out)["result"], "claimed");
    }

    let pin = work.pin(&id, socket);
    let meta = fs::symlink_metadata(&pin).unwrap();
    assert_eq!(
        (
            ino(&pin),
            meta.file_type().is_socket(),
            meta.mode() & 0o7777,
            meta.uid(),
            meta.nlink(),
        ),
        (
            ino(&work.jail(&id).join(socket)),
            true,
            0o600,
            nix::unistd::getuid().as_raw(),
            2,
        )
    );
    work.teardown(&id);
}

#[rstest]
#[case::api(SOCKETS[0])]
#[case::vsock(SOCKETS[1])]
fn claim_replaces_a_planted_symlink_pin_without_following_it_as_root(
    #[case] (op, socket): (&str, &str),
) {
    if !is_root() {
        eprintln!("SKIP claim symlink pin: needs root");
        return;
    }
    let mut work = Work::new();
    let id = unique("sym");
    work.boot(&id);
    let victim = work.tmp.path().join("victim");
    fs::write(&victim, b"keep").unwrap();
    fs::set_permissions(&victim, fs::Permissions::from_mode(0o644)).unwrap();
    let victim_before = fs::symlink_metadata(&victim).unwrap();
    symlink(&victim, work.pin(&id, socket)).unwrap();

    run(&work.config, json!({"op": op, "id": id})).success();

    let victim_after = fs::symlink_metadata(&victim).unwrap();
    assert_eq!(
        (
            fs::read(&victim).unwrap(),
            victim_after.mode(),
            victim_after.uid(),
            victim_after.nlink(),
            ino(&work.pin(&id, socket)),
        ),
        (
            b"keep".to_vec(),
            victim_before.mode(),
            victim_before.uid(),
            1,
            ino(&work.jail(&id).join(socket)),
        )
    );
    work.teardown(&id);
}

#[derive(Debug, Clone, Copy)]
enum Planted {
    Regular,
    Directory,
    Symlink,
    Fifo,
}

fn plant(at: &Path, what: Planted, decoy: &Path) {
    match what {
        Planted::Regular => fs::write(at, b"x").unwrap(),
        Planted::Directory => fs::create_dir(at).unwrap(),
        Planted::Symlink => symlink(decoy, at).unwrap(),
        Planted::Fifo => {
            nix::unistd::mkfifo(at, nix::sys::stat::Mode::from_bits_truncate(0o600)).unwrap()
        }
    }
}

#[rstest]
#[case::api_regular(SOCKETS[0], Planted::Regular)]
#[case::api_directory(SOCKETS[0], Planted::Directory)]
#[case::api_symlink_to_a_live_socket(SOCKETS[0], Planted::Symlink)]
#[case::vsock_fifo(SOCKETS[1], Planted::Fifo)]
#[case::vsock_symlink_to_a_live_socket(SOCKETS[1], Planted::Symlink)]
fn claim_of_a_non_socket_is_refused_and_pins_nothing_as_root(
    #[case] (op, socket): (&str, &str),
    #[case] planted: Planted,
) {
    if !is_root() {
        eprintln!("SKIP claim non-socket: needs root");
        return;
    }
    let work = Work::new();
    let id = unique("bad");
    let decoy = work.tmp.path().join("decoy.sock");
    let _decoy = UnixListener::bind(&decoy).unwrap();
    plant(&work.jail(&id).join(socket), planted, &decoy);

    let out = run(&work.config, json!({"op": op, "id": id})).failure();

    assert_eq!(
        (
            String::from_utf8_lossy(&out.get_output().stdout).contains("claimed"),
            work.pin(&id, socket).symlink_metadata().is_ok(),
        ),
        (false, false),
        "{planted:?}"
    );
    work.teardown(&id);
}

fn id_pair() -> impl Strategy<Value = (String, String)> {
    const ID: &str = "[a-zA-Z0-9][a-zA-Z0-9-]{0,12}";
    let suffix = prop_oneof![
        Just("api".to_owned()),
        Just("vsock".to_owned()),
        Just("api-socket".to_owned()),
        "[a-z0-9]{1,6}",
    ];
    (ID, suffix, ID, any::<bool>())
        .prop_map(|(a, suffix, other, prefixed)| {
            let b = if prefixed {
                format!("{a}-{suffix}")
            } else {
                other
            };
            (a, b)
        })
        .prop_filter("distinct ids", |(a, b)| a != b)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(10))]

    #[test]
    fn teardown_removes_exactly_its_own_pins_and_jail_as_root((a, b) in id_pair()) {
        if !is_root() {
            eprintln!("SKIP teardown scoping: needs root");
            return Ok(());
        }
        let tag = std::process::id();
        let (a, b) = (format!("{a}{tag}"), format!("{b}{tag}"));
        prop_assume!(a != b);
        let mut work = Work::new();
        work.boot(&a);
        work.boot(&b);
        work.claim_all(&a);
        work.claim_all(&b);
        let decoys = [
            format!("grpc-{a}.sock"),
            format!("fc-{a}-api.socket.old"),
            format!("fc-{a}-other.sock"),
            format!("fc-{a}"),
        ];
        for decoy in &decoys {
            fs::write(work.socks().join(decoy), b"").unwrap();
        }

        work.teardown(&a);

        let mut left: Vec<String> = fs::read_dir(work.socks())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        left.sort();
        let mut expected: Vec<String> = decoys
            .iter()
            .cloned()
            .chain(SOCKETS.iter().map(|(_, s)| format!("fc-{b}-{s}")))
            .collect();
        expected.sort();
        prop_assert_eq!(left, expected);
        prop_assert!(!work.srv.join("jails/firecracker").join(&a).exists());
        prop_assert!(work.jail(&b).join("api.socket").exists());
        work.teardown(&b);
    }
}

#[rstest]
fn teardown_is_idempotent_and_leaves_no_lock_file_as_root() {
    if !is_root() {
        eprintln!("SKIP teardown idempotence: needs root");
        return;
    }
    let mut work = Work::new();
    let id = unique("twice");
    work.boot(&id);
    work.claim_all(&id);

    work.teardown(&id);
    work.teardown(&id);
    fs::remove_dir(work.socks()).unwrap();
    work.teardown(&id);

    assert!(
        !Path::new(LOCKS).join(format!("vm-{id}")).exists(),
        "teardown must remove its lock file"
    );
}

#[rstest]
fn concurrent_teardowns_of_one_vm_all_succeed_as_root() {
    if !is_root() {
        eprintln!("SKIP concurrent teardown: needs root");
        return;
    }
    let mut work = Work::new();
    let id = unique("race");
    work.boot(&id);
    work.claim_all(&id);
    let request = json!({"op": "vm_teardown", "id": id}).to_string();

    let children: Vec<_> = (0..8)
        .map(|_| {
            support::command(&work.config, &[&request])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    let outcomes: Vec<(bool, String)> = children
        .into_iter()
        .map(|child| {
            let out = child.wait_with_output().unwrap();
            (
                out.status.success() && String::from_utf8_lossy(&out.stdout).contains("tore_down"),
                String::from_utf8_lossy(&out.stderr).into_owned(),
            )
        })
        .collect();

    let failed: Vec<&String> = outcomes
        .iter()
        .filter(|(ok, _)| !ok)
        .map(|(_, e)| e)
        .collect();
    assert!(failed.is_empty(), "teardowns failed: {failed:?}");
    assert!(!work.pin(&id, "api.socket").exists());
    assert!(!work.srv.join("jails/firecracker").join(&id).exists());
    assert!(!Path::new(LOCKS).join(format!("vm-{id}")).exists());
}
