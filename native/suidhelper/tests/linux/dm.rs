use hyper_suidhelper::linux::dm::ThinId;
use hyper_suidhelper::linux::dm::{DmName, Dmsetup, Inactive, SnapshotError, Thin, ThinPoolError};
use hyper_suidhelper::process::binary::RootSafeBin;
use proptest::prelude::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use tempfile::TempDir;

const DM_NAME_CHARS: &str =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#+-.:=@_";

fn dm_name() -> impl Strategy<Value = String> {
    "[0-9A-Za-z#+.:=@_][0-9A-Za-z#+.:=@_-]{0,126}".prop_filter("reserved", |s| {
        !matches!(s.as_str(), "." | ".." | "control")
    })
}

fn name(s: &str) -> DmName {
    s.parse().unwrap()
}

proptest! {
    #[test]
    fn dm_name_round_trips_and_lives_under_dev_mapper(s in dm_name()) {
        let dm: DmName = s.parse().unwrap();
        prop_assert_eq!(dm.to_string(), s.clone());
        let expected = format!("/dev/mapper/{s}");
        let path = dm.path();
        prop_assert_eq!(path.as_path(), Path::new(&expected));
    }

    #[test]
    fn dm_name_rejects_any_byte_outside_the_charset(
        s in dm_name(),
        at in any::<prop::sample::Index>(),
        bad in any::<char>().prop_filter("charset", |c| !DM_NAME_CHARS.contains(*c)),
    ) {
        let mut chars: Vec<char> = s.chars().collect();
        chars.insert(at.index(chars.len() + 1), bad);
        let s: String = chars.into_iter().collect();
        prop_assert!(s.parse::<DmName>().is_err(), "accepted {:?}", s);
    }

    #[test]
    fn dm_name_rejects_names_past_127_bytes(s in "[0-9A-Za-z]{128,200}") {
        prop_assert!(s.parse::<DmName>().is_err());
    }

    #[test]
    fn dm_name_rejects_a_leading_dash(s in dm_name()) {
        let dashed = format!("-{s}");
        prop_assert!(dashed.parse::<DmName>().is_err());
    }

    #[test]
    fn thin_id_accepts_exactly_24_bit_values(
        n in prop_oneof![0..=ThinId::MAX, (ThinId::MAX + 1)..=u32::MAX]
    ) {
        match ThinId::new(n) {
            Ok(id) => {
                prop_assert!(n <= ThinId::MAX);
                prop_assert_eq!(id.to_string(), n.to_string());
                prop_assert_eq!(n.to_string().parse::<ThinId>().unwrap(), id);
            }
            Err(_) => {
                prop_assert!(n > ThinId::MAX);
                prop_assert!(n.to_string().parse::<ThinId>().is_err());
            }
        }
    }

    #[test]
    fn thin_id_parse_rejects_non_integers(s in "[^0-9+]*|[0-9]+[^0-9]+[0-9]*") {
        prop_assert!(s.parse::<ThinId>().is_err());
    }
}

#[test]
fn dm_name_rejects_reserved_and_edge_names() {
    for bad in [
        "", ".", "..", "control", "-", "--help", "a/b", "/x", "a\0b", "a b",
    ] {
        assert!(bad.parse::<DmName>().is_err(), "accepted {bad:?}");
    }
}

const POOL_TABLE: &str = "0 100 thin-pool 7:0 7:1 128 0 0";

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

struct Fake {
    _dir: TempDir,
    log: PathBuf,
    dmsetup: Dmsetup,
}

impl Fake {
    fn new(table: &str, failing_message: &str) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let log = dir.path().join("calls");
        let bin = dir.path().join("dmsetup");
        let script = format!(
            "#!/bin/sh\n\
             printf '%s\\n' \"$*\" >> '{log}'\n\
             case \"$1\" in\n\
               table) printf '%s\\n' '{table}' ;;\n\
               message) [ \"$4\" = '{failing_message}' ] && exit 1 ;;\n\
             esac\n\
             exit 0\n",
            log = log.display(),
        );
        fs::write(&bin, script).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
        let dmsetup = Dmsetup::new(RootSafeBin::open(&bin).unwrap());
        Self {
            _dir: dir,
            log,
            dmsetup,
        }
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(str::to_string)
            .collect()
    }
}

#[test]
fn thin_pool_refuses_a_device_that_is_not_a_pool_as_root() {
    if !is_root() {
        eprintln!("SKIP thin_pool_refuses: needs root to own the fake dmsetup");
        return;
    }
    for table in [
        "0 100 linear 7:0 0",
        "0 100 thin /dev/mapper/hyper-pool 1",
        "",
    ] {
        let fake = Fake::new(table, "");
        let got = fake.dmsetup.thin_pool(&name("hyper-x"));
        assert!(
            matches!(got, Err(ThinPoolError::NotAThinPool { .. })),
            "{table:?}: {got:?}"
        );
        assert_eq!(fake.calls(), ["table hyper-x"], "{table:?}");
    }
}

#[test]
fn snapshot_always_resumes_the_origin_as_root() {
    if !is_root() {
        eprintln!("SKIP snapshot_always_resumes: needs root to own the fake dmsetup");
        return;
    }
    let ok: fn(&Result<Thin<Inactive>, SnapshotError>) -> bool = |r| {
        r.as_ref()
            .is_ok_and(|snap| snap.id() == ThinId::new(2).unwrap())
    };
    let create_snap_failed: fn(&Result<Thin<Inactive>, SnapshotError>) -> bool =
        |r| matches!(r, Err(SnapshotError::CreateSnap(_)));
    for (failing_message, expected) in [("", ok), ("create_snap 2 1", create_snap_failed)] {
        let fake = Fake::new(POOL_TABLE, failing_message);
        let pool = fake.dmsetup.thin_pool(&name("hyper-pool")).unwrap();
        let active = pool
            .create_thin(ThinId::new(1).unwrap())
            .unwrap()
            .activate(&name("hyper-vol"), 100, None)
            .unwrap();

        let got = active.snapshot(ThinId::new(2).unwrap());

        assert!(expected(&got), "{failing_message:?}: {got:?}");
        assert_eq!(
            fake.calls(),
            [
                "table hyper-pool",
                "message hyper-pool 0 create_thin 1",
                "create hyper-vol --table 0 100 thin /dev/mapper/hyper-pool 1",
                "suspend hyper-vol",
                "message hyper-pool 0 create_snap 2 1",
                "resume hyper-vol",
            ],
            "{failing_message:?}"
        );
    }
}

#[test]
fn deactivate_then_delete_removes_the_device_then_frees_its_id_as_root() {
    if !is_root() {
        eprintln!("SKIP delete_removes: needs root to own the fake dmsetup");
        return;
    }
    let fake = Fake::new(POOL_TABLE, "");
    let pool = fake.dmsetup.thin_pool(&name("hyper-pool")).unwrap();
    pool.create_thin(ThinId::new(1).unwrap())
        .unwrap()
        .activate(&name("hyper-vol"), 100, None)
        .unwrap()
        .deactivate()
        .unwrap()
        .delete()
        .unwrap();

    assert_eq!(
        fake.calls()[3..],
        ["remove --retry hyper-vol", "message hyper-pool 0 delete 1"]
    );
}
