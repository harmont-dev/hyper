use super::{Device, DmName, DmTable, Dmsetup, RemoveMode, RunError, ThinTable};
use crate::fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use crate::linux::Access;
use derive_more::{Display, Into};
use std::ffi::OsStr;
use std::num::ParseIntError;
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display, Into)]
#[into(u64)]
pub struct ThinId(u32);

#[derive(Debug, ThisError)]
#[error("thin device id {0} exceeds the 24-bit limit")]
pub struct ThinIdOutOfRange(u32);

#[derive(Debug, ThisError)]
pub enum ParseThinIdError {
    #[error("thin device id is not an integer: {0}")]
    Int(#[from] ParseIntError),
    #[error(transparent)]
    OutOfRange(#[from] ThinIdOutOfRange),
}

impl ThinId {
    pub const MAX: u32 = (1 << 24) - 1;

    pub fn new(id: u32) -> Result<Self, ThinIdOutOfRange> {
        if id <= Self::MAX {
            Ok(Self(id))
        } else {
            Err(ThinIdOutOfRange(id))
        }
    }
}

impl FromStr for ThinId {
    type Err = ParseThinIdError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(Self::new(s.parse()?)?)
    }
}

#[derive(Debug, ThisError)]
pub enum ThinPoolError {
    #[error(transparent)]
    Run(#[from] RunError),
    #[error("{name} is not a thin-pool device: {table:?}")]
    NotAThinPool { name: DmName, table: String },
}

#[derive(Debug, ThisError)]
pub enum SnapshotError {
    #[error("suspending origin: {0}")]
    Suspend(#[source] RunError),
    #[error("sending create_snap: {0}")]
    CreateSnap(#[source] RunError),
    #[error("resuming origin: {0}")]
    Resume(#[source] RunError),
}

#[derive(Debug, Clone)]
pub struct ThinPool<'a> {
    device: Device<'a>,
}

#[derive(Debug, Clone, Copy)]
pub struct Inactive;

#[derive(Debug)]
pub struct Active<'a>(Device<'a>);

#[derive(Debug)]
pub struct Thin<'a, S> {
    pool: ThinPool<'a>,
    id: ThinId,
    state: S,
}

impl<'a> ThinPool<'a> {
    pub(super) fn open(dmsetup: &'a Dmsetup, name: &DmName) -> Result<Self, ThinPoolError> {
        let table = dmsetup.run([OsStr::new("table"), name.as_os_str()])?;
        match table.lines().collect::<Vec<_>>().as_slice() {
            [line] if line.split_whitespace().nth(2) == Some("thin-pool") => Ok(Self {
                device: dmsetup.device(name),
            }),
            _ => Err(ThinPoolError::NotAThinPool {
                name: name.clone(),
                table,
            }),
        }
    }

    pub fn device(&self) -> &Device<'a> {
        &self.device
    }

    pub fn create_thin(&self, id: ThinId) -> Result<Thin<'a, Inactive>, RunError> {
        self.message(&format!("create_thin {id}"))?;
        Ok(Thin {
            pool: self.clone(),
            id,
            state: Inactive,
        })
    }

    pub fn create_snap(&self, id: ThinId, origin: ThinId) -> Result<(), RunError> {
        self.message(&format!("create_snap {id} {origin}"))
    }

    pub fn delete_thin(&self, id: ThinId) -> Result<(), RunError> {
        self.message(&format!("delete {id}"))
    }

    pub fn reserve_metadata_snap(&self) -> Result<(), RunError> {
        self.message("reserve_metadata_snap")
    }

    pub fn release_metadata_snap(&self) -> Result<(), RunError> {
        self.message("release_metadata_snap")
    }

    fn message(&self, message: &str) -> Result<(), RunError> {
        self.device
            .dmsetup
            .run([
                OsStr::new("message"),
                self.device.name().as_os_str(),
                OsStr::new("0"),
                OsStr::new(message),
            ])
            .map(drop)
    }
}

impl<S> Thin<'_, S> {
    pub fn id(&self) -> ThinId {
        self.id
    }
}

impl<'a> Thin<'a, Inactive> {
    pub fn activate(
        self,
        name: &DmName,
        sectors: u64,
        origin: Option<SafePathBuf<IsAbsolute, StrictComponents>>,
    ) -> Result<Thin<'a, Active<'a>>, RunError> {
        let table = DmTable::Thin(ThinTable {
            sectors,
            pool: self.pool.device.name().clone(),
            id: self.id,
            origin,
        });
        let device = self
            .pool
            .device
            .dmsetup
            .create(name, &table, Access::ReadWrite)?;
        Ok(Thin {
            pool: self.pool,
            id: self.id,
            state: Active(device),
        })
    }

    pub fn delete(self) -> Result<(), RunError> {
        self.pool.delete_thin(self.id)
    }
}

impl<'a> Thin<'a, Active<'a>> {
    pub fn device(&self) -> &Device<'a> {
        &self.state.0
    }

    pub fn snapshot(&self, new_id: ThinId) -> Result<Thin<'a, Inactive>, SnapshotError> {
        let device = self.device();
        device.suspend().map_err(SnapshotError::Suspend)?;
        let snapped = self.pool.create_snap(new_id, self.id);
        device.resume().map_err(SnapshotError::Resume)?;
        snapped.map_err(SnapshotError::CreateSnap)?;
        Ok(Thin {
            pool: self.pool.clone(),
            id: new_id,
            state: Inactive,
        })
    }

    pub fn deactivate(self) -> Result<Thin<'a, Inactive>, RunError> {
        self.state.0.remove(RemoveMode::Retry)?;
        Ok(Thin {
            pool: self.pool,
            id: self.id,
            state: Inactive,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{Inactive, SnapshotError, Thin, ThinId, ThinPoolError};
    use crate::linux::dm::{DmName, Dmsetup};
    use crate::process::binary::RootSafeBin;
    use proptest::prelude::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use tempfile::TempDir;

    proptest! {
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

    const POOL_TABLE: &str = "0 100 thin-pool 7:0 7:1 128 0 0";

    fn name(s: &str) -> DmName {
        s.parse().unwrap()
    }

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
}
