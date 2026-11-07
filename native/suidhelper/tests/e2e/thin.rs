#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

mod support;
use support::{is_root, run, stdout_json, MapperDevice};

const POOL: &str = "table hyper-pool";
const PARENT: &str = "table hyper-vm1";
const POOL_NUMBER: &str = "info -c --noheadings -o major,minor hyper-pool";

struct Pool {
    dir: TempDir,
    config: PathBuf,
    origin: MapperDevice,
}

impl Pool {
    fn origin(&self) -> String {
        self.origin.path()
    }

    fn parent_table(&self, table: &str) {
        fs::write(
            self.dir.path().join("table-hyper-vm1"),
            format!("{table}\n"),
        )
        .unwrap();
    }

    fn fail(&self, verb: &str) {
        fs::write(self.dir.path().join(format!("fail-{verb}")), b"").unwrap();
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(self.dir.path().join("dmsetup.log"))
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }

    fn request(&self, op: &str, fields: Value) -> Value {
        let mut request = json!({"op": op, "pool": "hyper-pool"});
        request
            .as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        request
    }
}

#[fixture]
fn pool() -> Option<Pool> {
    let dir = TempDir::new().unwrap();
    let base = fs::canonicalize(dir.path()).unwrap();
    let dmsetup = base.join("dmsetup");
    fs::write(
        &dmsetup,
        format!(
            r#"#!/bin/sh
printf '%s\n' "$*" >> '{base}/dmsetup.log'
verb="$1"
[ "$1" = message ] && verb="msg-${{4%% *}}"
if [ -e "{base}/fail-$verb" ]; then echo "$verb failed" >&2; exit 1; fi
case "$1" in
  table)
    if [ "$2" = hyper-pool ]; then printf '0 2048 thin-pool 7:0 7:1 128 0 0\n'
    else cat "{base}/table-$2" 2>/dev/null; fi ;;
  info) printf '253:1\n' ;;
esac
exit 0
"#,
            base = base.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&dmsetup, fs::Permissions::from_mode(0o755)).unwrap();
    let config = base.join("config.toml");
    fs::write(
        &config,
        format!(
            "work_dir = \"{}\"\n[tools]\ndmsetup = \"{}\"\n",
            base.display(),
            dmsetup.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o644)).unwrap();
    let backing = base.join("origin.img");
    fs::write(&backing, vec![0u8; 1024 * 1024]).unwrap();
    let origin = MapperDevice::linear(
        &format!("hyper-e2e-thin-origin-{}", std::process::id()),
        &backing,
    )?;
    Some(Pool {
        dir,
        config,
        origin,
    })
}

macro_rules! require {
    ($pool:expr) => {
        match (is_root(), $pool) {
            (true, Some(pool)) => pool,
            _ => {
                eprintln!("SKIP: needs root and losetup/dmsetup");
                return;
            }
        }
    };
}

#[rstest]
fn thin_create_allocates_the_id_then_activates_it_sized_by_its_origin_as_root(pool: Option<Pool>) {
    let pool = require!(pool);
    let request = pool.request(
        "thin_create",
        json!({"thin_id": 7, "name": "hyper-vm1", "origin": pool.origin()}),
    );

    let out = stdout_json(&run(&pool.config, request).success());

    assert_eq!(out["device"], "/dev/mapper/hyper-vm1");
    assert_eq!(
        pool.calls(),
        [
            POOL.to_string(),
            "message hyper-pool 0 create_thin 7".to_string(),
            format!(
                "create hyper-vm1 --table 0 2048 thin /dev/mapper/hyper-pool 7 {}",
                pool.origin()
            ),
        ]
    );
}

#[rstest]
fn thin_create_frees_the_id_when_activation_fails_as_root(pool: Option<Pool>) {
    let pool = require!(pool);
    pool.fail("create");
    let request = pool.request(
        "thin_create",
        json!({"thin_id": 7, "name": "hyper-vm1", "origin": pool.origin()}),
    );

    run(&pool.config, request).code(2);

    assert_eq!(
        pool.calls().last().map(String::as_str),
        Some("message hyper-pool 0 delete 7")
    );
}

#[rstest]
#[case::succeeds(None, true, &["msg-create_snap", "resume", "create"])]
#[case::create_snap_fails(Some("msg-create_snap"), false, &["msg-create_snap", "resume"])]
#[case::resume_fails(Some("resume"), false, &["msg-create_snap", "resume", "msg-delete"])]
#[case::activation_fails(Some("create"), false, &["msg-create_snap", "resume", "create", "msg-delete"])]
fn thin_snapshot_freezes_the_parent_only_around_create_snap_as_root(
    pool: Option<Pool>,
    #[case] failing: Option<&str>,
    #[case] succeeds: bool,
    #[case] after_suspend: &[&str],
) {
    let pool = require!(pool);
    pool.parent_table("0 2048 thin 253:1 7");
    if let Some(verb) = failing {
        pool.fail(verb);
    }
    let request = pool.request(
        "thin_snapshot",
        json!({"parent": "hyper-vm1", "thin_id": 8, "name": "hyper-fork", "origin": pool.origin()}),
    );

    let out = run(&pool.config, request);
    if succeeds {
        out.success();
    } else {
        out.code(2);
    }

    let verb = |call: &String| match call.split(' ').collect::<Vec<_>>()[..] {
        ["message", _, _, message, ..] => format!("msg-{message}"),
        [verb, ..] => verb.to_string(),
        [] => String::new(),
    };
    let calls = pool.calls();
    assert_eq!(calls[..4], [POOL, PARENT, POOL_NUMBER, "suspend hyper-vm1"]);
    assert_eq!(
        calls[4..].iter().map(verb).collect::<Vec<_>>(),
        after_suspend
    );
    assert!(calls.contains(&"message hyper-pool 0 create_snap 8 7".to_string()));
    if succeeds {
        assert_eq!(
            calls.last().unwrap(),
            &format!(
                "create hyper-fork --table 0 2048 thin /dev/mapper/hyper-pool 8 {}",
                pool.origin()
            )
        );
    }
}

#[rstest]
#[case::linear("0 2048 linear 7:0 0")]
#[case::thin_of_another_pool("0 2048 thin 253:9 7")]
#[case::absent("")]
fn thin_snapshot_refuses_a_parent_that_is_not_a_thin_of_the_pool_as_root(
    pool: Option<Pool>,
    #[case] table: &str,
) {
    let pool = require!(pool);
    pool.parent_table(table);
    let request = pool.request(
        "thin_snapshot",
        json!({"parent": "hyper-vm1", "thin_id": 8, "name": "hyper-fork", "origin": pool.origin()}),
    );

    run(&pool.config, request).code(2);

    assert_eq!(pool.calls(), [POOL, PARENT, POOL_NUMBER]);
}

#[rstest]
fn thin_destroy_removes_the_device_then_frees_the_id_it_reports_as_root(pool: Option<Pool>) {
    let pool = require!(pool);
    pool.parent_table("0 2048 thin 253:1 7");

    run(
        &pool.config,
        pool.request("thin_destroy", json!({"name": "hyper-vm1"})),
    )
    .success();

    assert_eq!(
        pool.calls(),
        [
            POOL,
            PARENT,
            POOL_NUMBER,
            "remove --retry hyper-vm1",
            "message hyper-pool 0 delete 7",
        ]
    );
}

#[rstest]
fn thin_destroy_refuses_a_device_that_is_not_a_thin_of_the_pool_as_root(pool: Option<Pool>) {
    let pool = require!(pool);
    pool.parent_table("0 2048 linear 7:0 0");

    run(
        &pool.config,
        pool.request("thin_destroy", json!({"name": "hyper-vm1"})),
    )
    .code(2);

    assert_eq!(pool.calls(), [POOL, PARENT, POOL_NUMBER]);
}

#[rstest]
#[case::foreign_pool("thin_create", json!({"pool": "vg0-pool", "thin_id": 1, "name": "hyper-vm1",
    "origin": "/dev/mapper/hyper-img"}))]
#[case::foreign_name("thin_create", json!({"thin_id": 1, "name": "sda1",
    "origin": "/dev/mapper/hyper-img"}))]
#[case::foreign_origin("thin_create", json!({"thin_id": 1, "name": "hyper-vm1",
    "origin": "/dev/mapper/root"}))]
#[case::foreign_parent("thin_snapshot", json!({"parent": "root", "thin_id": 2,
    "name": "hyper-fork", "origin": "/dev/mapper/hyper-img"}))]
#[case::foreign_destroy("thin_destroy", json!({"name": "root"}))]
fn foreign_devices_are_refused_before_dmsetup_runs_as_root(
    pool: Option<Pool>,
    #[case] op: &str,
    #[case] fields: Value,
) {
    let pool = require!(pool);

    run(&pool.config, pool.request(op, fields)).code(2);

    assert!(pool.calls().is_empty());
}
