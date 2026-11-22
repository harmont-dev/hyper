#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::json;
use std::fs;
use std::os::unix::fs::{symlink, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;

mod support;
use support::{is_root, run, stdout_json};

const GID: u32 = 900_001;

struct Work {
    _tmp: TempDir,
    srv: PathBuf,
    config: PathBuf,
    _listeners: Vec<UnixListener>,
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
            _tmp: tmp,
            srv,
            config,
            _listeners: Vec::new(),
        }
    }

    fn jail(&self, id: &str) -> PathBuf {
        let root = self.srv.join("jails/firecracker").join(id).join("root");
        fs::create_dir_all(&root).unwrap();
        root
    }

    fn listener(&self, id: &str) -> PathBuf {
        self.srv.join("socks").join(format!("fc-{id}-guest.sock"))
    }

    fn listen(&mut self, id: &str) -> PathBuf {
        let path = self.listener(id);
        self._listeners.push(UnixListener::bind(&path).unwrap());
        path
    }

    fn link(&self, id: &str, gid: u32) -> assert_cmd::assert::Assert {
        run(
            &self.config,
            json!({"op": "vm_link_guest_socket", "id": id, "gid": gid}),
        )
    }
}

fn unique(tag: &str) -> String {
    format!("{tag}{}", std::process::id())
}

#[rstest]
fn a_lone_listener_is_linked_into_the_jail_for_its_group_as_root() {
    if !is_root() {
        eprintln!("SKIP guest link: needs root");
        return;
    }
    let mut work = Work::new();
    let id = unique("link");
    let jail = work.jail(&id);
    let listener = work.listen(&id);

    for _ in 0..2 {
        let out = work.link(&id, GID).success();
        assert_eq!(stdout_json(&out)["result"], "linked");
    }

    let linked = fs::symlink_metadata(jail.join("vsock.sock_1100")).unwrap();
    let host = fs::symlink_metadata(&listener).unwrap();
    assert_eq!(
        (
            linked.file_type().is_socket(),
            linked.ino(),
            linked.mode() & 0o7777,
            linked.gid(),
            linked.nlink()
        ),
        (true, host.ino(), 0o660, GID, 2)
    );
}

#[rstest]
fn before_the_jail_exists_the_link_is_pending_as_root() {
    if !is_root() {
        eprintln!("SKIP guest link pending: needs root");
        return;
    }
    let mut work = Work::new();
    let id = unique("pend");
    work.listen(&id);

    let out = work.link(&id, GID).success();
    assert_eq!(stdout_json(&out)["result"], "pending");
}

#[rstest]
fn with_no_listener_the_link_fails() {
    let work = Work::new();
    let id = unique("none");
    work.jail(&id);

    let out = work.link(&id, GID).failure();
    assert!(
        String::from_utf8_lossy(&out.get_output().stderr).contains("no guest socket"),
        "{out:?}"
    );
}

fn alias_of_another_socket(work: &mut Work, id: &str) {
    let other = work.listen("other");
    fs::hard_link(other, work.listener(id)).unwrap();
}

fn symlink_to_another_socket(work: &mut Work, id: &str) {
    let other = work.listen("other");
    symlink(other, work.listener(id)).unwrap();
}

#[rstest]
#[case::second_name_of_another_socket(alias_of_another_socket)]
#[case::symlink_to_another_socket(symlink_to_another_socket)]
fn a_listener_name_that_is_not_a_lone_socket_is_refused_and_links_nothing_as_root(
    #[case] plant: fn(&mut Work, &str),
) {
    if !is_root() {
        eprintln!("SKIP guest link refusal: needs root");
        return;
    }
    let mut work = Work::new();
    let id = unique("shared");
    let jail = work.jail(&id);
    plant(&mut work, &id);

    work.link(&id, GID).failure();
    assert!(fs::symlink_metadata(jail.join("vsock.sock_1100")).is_err());
}

#[rstest]
fn a_gid_outside_the_jail_range_is_refused() {
    let mut work = Work::new();
    let id = unique("gid");
    let jail = work.jail(&id);
    work.listen(&id);

    work.link(&id, 0).failure();
    assert!(fs::symlink_metadata(jail.join("vsock.sock_1100")).is_err());
}
