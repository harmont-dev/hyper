//! `vm_claim_*_socket` through a real setuid install, called by a non-root member of the helper's
//! group the way the node calls it (#135: "keep VM sockets private").
//!
//! Laws:
//! - the pin is the jail socket's own inode, handed to the *calling* user and group (never to the
//!   effective root the setuid bit grants), mode `0600`;
//! - once claimed, only that caller and root can `connect()` to the VM's API or vsock socket, by
//!   the pin or by the jail path: another member of the helper's group, another VM's jail uid and
//!   `nobody` are all refused `EACCES` by the socket itself, even through a traversable dir;
//! - a socket dir that is a symlink is refused (`ELOOP`) by both claim and teardown, and nothing
//!   is linked into or unlinked from the symlink's target;
//! - a socket dir that is not a directory is a refusal, never a crash.
#![cfg(feature = "insecure_mode")]

use nix::unistd::{Gid, Uid};
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::json;
use std::fs;
use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

mod setuid_support;
mod support;
use setuid_support::{run_as, Caller, Install, MEMBER, OTHER_MEMBER, ROOT};
use support::is_root;

const ID: &str = "v1";

const SOCKETS: [(&str, &str); 2] = [
    ("vm_claim_api_socket", "api.socket"),
    ("vm_claim_vsock_socket", "vsock.sock"),
];

const OTHER_VMS_JAIL: Caller = Caller {
    uid: 900_003,
    gid: 900_003,
    groups: &[],
};

const NOBODY: Caller = Caller {
    uid: 65_534,
    gid: 65_534,
    groups: &[],
};

struct Vm {
    install: Install,
    config: PathBuf,
    srv: PathBuf,
    _listeners: Vec<UnixListener>,
}

impl Vm {
    fn new() -> Self {
        let install = Install::new();
        let srv = install.path().join("srv");
        let root = srv.join("jails/firecracker").join(ID).join("root");
        fs::create_dir_all(&root).unwrap();
        let socks = srv.join("socks");
        fs::create_dir_all(&socks).unwrap();
        chown(&socks, MEMBER);
        fs::set_permissions(&socks, fs::Permissions::from_mode(0o755)).unwrap();
        let listeners = SOCKETS
            .iter()
            .map(|(_, socket)| {
                let path = root.join(socket);
                let listener = UnixListener::bind(&path).unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o777)).unwrap();
                listener
            })
            .collect();
        let config = install.config(&srv);
        Self {
            install,
            config,
            srv,
            _listeners: listeners,
        }
    }

    fn jail_socket(&self, socket: &str) -> PathBuf {
        self.srv
            .join("jails/firecracker")
            .join(ID)
            .join("root")
            .join(socket)
    }

    fn pin(&self, socket: &str) -> PathBuf {
        self.srv.join("socks").join(format!("fc-{ID}-{socket}"))
    }
}

fn chown(path: &Path, caller: Caller) {
    nix::unistd::chown(
        path,
        Some(Uid::from_raw(caller.uid)),
        Some(Gid::from_raw(caller.gid)),
    )
    .unwrap();
}

/// `connect()` to `path` as `caller`: `0` on success, otherwise the errno.
fn connect_as(caller: Caller, path: &Path) -> i32 {
    let Caller { uid, gid, groups } = caller;
    let mut cmd = Command::new("python3");
    cmd.args([
        "-I",
        "-c",
        "import socket,sys\ns=socket.socket(socket.AF_UNIX)\ntry:\n s.connect(sys.argv[1]); print(0)\nexcept OSError as e:\n print(e.errno)",
    ])
    .arg(path)
    .env_clear();
    // SAFETY: the hook runs in the forked child before exec and makes only raw id syscalls.
    unsafe {
        cmd.pre_exec(move || {
            let groups: Vec<Gid> = groups.iter().copied().map(Gid::from_raw).collect();
            nix::unistd::setgroups(&groups)?;
            nix::unistd::setresgid(Gid::from_raw(gid), Gid::from_raw(gid), Gid::from_raw(gid))?;
            nix::unistd::setresuid(Uid::from_raw(uid), Uid::from_raw(uid), Uid::from_raw(uid))?;
            Ok(())
        })
    };
    let out = cmd.output().unwrap();
    String::from_utf8_lossy(&out.stdout)
        .trim()
        .parse()
        .unwrap_or_else(|_| panic!("connect probe failed: {out:?}"))
}

#[rstest]
#[case::api(SOCKETS[0])]
#[case::vsock(SOCKETS[1])]
fn a_member_claim_hands_the_socket_to_the_caller_alone_as_root(#[case] (op, socket): (&str, &str)) {
    if !is_root() {
        eprintln!("SKIP setuid claim: needs root to install setuid");
        return;
    }
    let vm = Vm::new();

    let out = run_as(
        &vm.install,
        &vm.config,
        MEMBER,
        &json!({"op": op, "id": ID}),
    );

    let pin = fs::symlink_metadata(vm.pin(socket)).unwrap();
    let jail = fs::symlink_metadata(vm.jail_socket(socket)).unwrap();
    assert_eq!(
        (
            out.code,
            out.stdout.trim(),
            pin.file_type().is_socket(),
            (pin.dev(), pin.ino()),
            (pin.uid(), pin.gid()),
            pin.mode() & 0o7777,
        ),
        (
            Some(0),
            r#"{"result":"claimed"}"#,
            true,
            (jail.dev(), jail.ino()),
            (MEMBER.uid, MEMBER.gid),
            0o600,
        ),
        "{}",
        out.stderr
    );
}

const EACCES: i32 = 13;

#[rstest]
#[case::api(SOCKETS[0])]
#[case::vsock(SOCKETS[1])]
fn once_claimed_only_the_caller_and_root_can_connect_as_root(#[case] (op, socket): (&str, &str)) {
    if !is_root() {
        eprintln!("SKIP setuid claim privacy: needs root to install setuid");
        return;
    }
    let vm = Vm::new();
    run_as(
        &vm.install,
        &vm.config,
        MEMBER,
        &json!({"op": op, "id": ID}),
    );

    let callers = [
        ("caller", MEMBER),
        ("root", ROOT),
        ("other member", OTHER_MEMBER),
        ("other VM's jail uid", OTHER_VMS_JAIL),
        ("nobody", NOBODY),
    ];
    let got: Vec<(&str, i32, i32)> = callers
        .iter()
        .map(|&(who, caller)| {
            (
                who,
                connect_as(caller, &vm.pin(socket)),
                connect_as(caller, &vm.jail_socket(socket)),
            )
        })
        .collect();

    assert_eq!(
        got,
        vec![
            ("caller", 0, 0),
            ("root", 0, 0),
            ("other member", EACCES, EACCES),
            ("other VM's jail uid", EACCES, EACCES),
            ("nobody", EACCES, EACCES),
        ]
    );
}

#[rstest]
#[case::claim_api(json!({"op": "vm_claim_api_socket", "id": ID}))]
#[case::claim_vsock(json!({"op": "vm_claim_vsock_socket", "id": ID}))]
#[case::teardown(json!({"op": "vm_teardown", "id": ID}))]
fn a_symlinked_socket_dir_is_refused_and_its_target_untouched_as_root(
    #[case] request: serde_json::Value,
) {
    if !is_root() {
        eprintln!("SKIP symlinked socket dir: needs root to install setuid");
        return;
    }
    let vm = Vm::new();
    let elsewhere = vm.install.path().join("elsewhere");
    fs::create_dir(&elsewhere).unwrap();
    chown(&elsewhere, MEMBER);
    let decoy = elsewhere.join(format!("fc-{ID}-vsock.sock"));
    fs::write(&decoy, b"decoy").unwrap();
    fs::remove_dir(vm.srv.join("socks")).unwrap();
    symlink(&elsewhere, vm.srv.join("socks")).unwrap();

    let out = run_as(&vm.install, &vm.config, MEMBER, &request);

    let mut left: Vec<String> = fs::read_dir(&elsewhere)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    left.sort();
    assert_eq!(
        (
            out.code,
            out.stderr.contains("ELOOP"),
            left,
            fs::read(&decoy).unwrap()
        ),
        (
            Some(2),
            true,
            vec![format!("fc-{ID}-vsock.sock")],
            b"decoy".to_vec()
        ),
        "{request}: {}",
        out.stderr
    );
}

#[rstest]
#[case::api(SOCKETS[0])]
#[case::vsock(SOCKETS[1])]
fn a_socket_dir_that_is_a_file_is_refused_not_crashed_as_root(#[case] (op, _): (&str, &str)) {
    if !is_root() {
        eprintln!("SKIP socket dir file: needs root to install setuid");
        return;
    }
    let vm = Vm::new();
    fs::remove_dir(vm.srv.join("socks")).unwrap();
    fs::write(vm.srv.join("socks"), b"not a dir").unwrap();

    let out = run_as(
        &vm.install,
        &vm.config,
        MEMBER,
        &json!({"op": op, "id": ID}),
    );

    assert_eq!(
        (
            out.code,
            out.stdout.as_str(),
            out.stderr.contains("socket dir")
        ),
        (Some(2), "", true),
        "{}",
        out.stderr
    );
}
