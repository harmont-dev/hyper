use super::{Device, DmName, DmTable, Dmsetup, Origin, RemoveMode, RunError, ThinTable};
use crate::Access;
use derive_more::{Display, Into};
use std::ffi::OsStr;
use std::num::ParseIntError;
use std::str::FromStr;
use thiserror::Error as ThisError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Display, Into)]
#[cfg_attr(feature = "serde", derive(serde::Deserialize), serde(try_from = "u32"))]
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
        Self::try_from(id)
    }
}

impl TryFrom<u32> for ThinId {
    type Error = ThinIdOutOfRange;

    fn try_from(id: u32) -> Result<Self, ThinIdOutOfRange> {
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

/// A thin-pool message we permit: provision, snapshot, or drop a thin device by id, or pin/unpin the pool's metadata snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Display)]
pub enum ThinMessage {
    #[display("create_thin {_0}")]
    CreateThin(ThinId),
    #[display("create_snap {id} {origin}")]
    CreateSnap { id: ThinId, origin: ThinId },
    #[display("delete {_0}")]
    Delete(ThinId),
    #[display("reserve_metadata_snap")]
    ReserveMetadataSnap,
    #[display("release_metadata_snap")]
    ReleaseMetadataSnap,
}

#[derive(Debug, ThisError)]
pub enum ParseThinMessageError {
    #[error("unsupported thin-pool message: {0}")]
    Malformed(String),
    #[error(transparent)]
    ThinId(#[from] ParseThinIdError),
}

impl FromStr for ThinMessage {
    type Err = ParseThinMessageError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.split_whitespace().collect::<Vec<_>>().as_slice() {
            ["create_thin", i] => Ok(ThinMessage::CreateThin(i.parse()?)),
            ["create_snap", new, orig] => Ok(ThinMessage::CreateSnap {
                id: new.parse()?,
                origin: orig.parse()?,
            }),
            ["delete", i] => Ok(ThinMessage::Delete(i.parse()?)),
            ["reserve_metadata_snap"] => Ok(ThinMessage::ReserveMetadataSnap),
            ["release_metadata_snap"] => Ok(ThinMessage::ReleaseMetadataSnap),
            _ => Err(ParseThinMessageError::Malformed(s.to_string())),
        }
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
pub enum OpenThinError {
    #[error(transparent)]
    Run(#[from] RunError),
    #[error("{name} is not a thin device of this pool: {table:?}")]
    NotAThin { name: DmName, table: String },
    #[error(transparent)]
    Id(#[from] ParseThinIdError),
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
        let table = dmsetup.run([OsStr::new("table"), name.as_ref()])?;
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
        self.send(ThinMessage::CreateThin(id))?;
        Ok(Thin {
            pool: self.clone(),
            id,
            state: Inactive,
        })
    }

    pub fn open_thin(&self, name: &DmName) -> Result<Thin<'a, Active<'a>>, OpenThinError> {
        let dmsetup = self.device.dmsetup;
        let table = dmsetup.run([OsStr::new("table"), name.as_ref()])?;
        let pool = self.device.number()?;
        let not_a_thin = || OpenThinError::NotAThin {
            name: name.clone(),
            table: table.clone(),
        };
        let [line] = table.lines().collect::<Vec<_>>()[..] else {
            return Err(not_a_thin());
        };
        match line.split_whitespace().collect::<Vec<_>>()[..] {
            [_, _, "thin", dev, id, ..] if dev == pool => Ok(Thin {
                pool: self.clone(),
                id: id.parse()?,
                state: Active(dmsetup.device(name)),
            }),
            _ => Err(not_a_thin()),
        }
    }

    pub fn create_snap(&self, id: ThinId, origin: ThinId) -> Result<(), RunError> {
        self.send(ThinMessage::CreateSnap { id, origin })
    }

    pub fn delete_thin(&self, id: ThinId) -> Result<(), RunError> {
        self.send(ThinMessage::Delete(id))
    }

    pub fn reserve_metadata_snap(&self) -> Result<(), RunError> {
        self.send(ThinMessage::ReserveMetadataSnap)
    }

    pub fn release_metadata_snap(&self) -> Result<(), RunError> {
        self.send(ThinMessage::ReleaseMetadataSnap)
    }

    pub fn send(&self, message: ThinMessage) -> Result<(), RunError> {
        let message = message.to_string();
        self.device
            .dmsetup
            .run([
                OsStr::new("message"),
                self.device.name().as_ref(),
                OsStr::new("0"),
                OsStr::new(&message),
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
        origin: Option<Origin>,
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
    use super::{
        Inactive, OpenThinError, ParseThinMessageError, SnapshotError, Thin, ThinId, ThinMessage,
        ThinPoolError,
    };
    use crate::dm::{DmName, Dmsetup};
    use assert_fs::fixture::ChildPath;
    use assert_fs::prelude::*;
    use assert_fs::TempDir;
    use hyperrs_process::binary::RootSafeBin;
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::assert_matches;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use test_strategy::proptest;

    #[proptest]
    fn thin_id_accepts_exactly_24_bit_values(
        #[strategy(prop_oneof![0..=ThinId::MAX, (ThinId::MAX + 1)..=u32::MAX])] n: u32,
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

    #[proptest]
    fn thin_id_parse_rejects_non_integers(#[strategy("[^0-9+]*|[0-9]+[^0-9]+[0-9]*")] s: String) {
        prop_assert!(s.parse::<ThinId>().is_err());
    }

    #[proptest]
    fn message_parse_is_the_inverse_of_render(#[strategy(message())] m: ThinMessage) {
        prop_assert_eq!(m.to_string().parse::<ThinMessage>().unwrap(), m);
    }

    #[proptest]
    fn message_parse_ignores_surrounding_and_inner_spacing(
        #[strategy(message())] m: ThinMessage,
        #[strategy("[ \t]{1,3}")] pad: String,
    ) {
        let spaced = format!(
            "{pad}{}{pad}",
            m.to_string().split(' ').collect::<Vec<_>>().join(&pad)
        );
        prop_assert_eq!(spaced.parse::<ThinMessage>().unwrap(), m);
    }

    #[proptest]
    fn message_with_an_extra_operand_is_refused(
        #[strategy(message())] m: ThinMessage,
        #[strategy("[0-9]{1,4}")] extra: String,
    ) {
        let s = format!("{m} {extra}");
        assert_matches!(
            s.parse::<ThinMessage>(),
            Err(ParseThinMessageError::Malformed(_)),
            "accepted {s:?}"
        );
    }

    fn thin_id() -> impl Strategy<Value = ThinId> {
        (0..=ThinId::MAX).prop_map(|n| ThinId::new(n).unwrap())
    }

    fn message() -> impl Strategy<Value = ThinMessage> {
        prop_oneof![
            thin_id().prop_map(ThinMessage::CreateThin),
            (thin_id(), thin_id()).prop_map(|(id, origin)| ThinMessage::CreateSnap { id, origin }),
            thin_id().prop_map(ThinMessage::Delete),
            Just(ThinMessage::ReserveMetadataSnap),
            Just(ThinMessage::ReleaseMetadataSnap),
        ]
    }

    #[rstest]
    #[case::unknown_verb("resize 10")]
    #[case::create_thin_without_id("create_thin")]
    #[case::delete_without_id("delete")]
    #[case::non_numeric_delete_id("delete x")]
    #[case::empty("")]
    #[case::negative_create_thin_id("create_thin -1")]
    #[case::create_snap_without_ids("create_snap")]
    #[case::create_snap_without_origin("create_snap 1")]
    #[case::non_numeric_snap_id("create_snap x 2")]
    #[case::non_numeric_snap_origin("create_snap 1 y")]
    #[case::negative_snap_id("create_snap -1 2")]
    #[case::truncated_verb("reserve_metadata")]
    #[case::create_thin_id_past_24_bits("create_thin 16777216")]
    #[case::delete_id_past_24_bits("delete 16777216")]
    #[case::snap_origin_past_24_bits("create_snap 1 16777216")]
    fn message_rejects_strings_outside_the_grammar(#[case] bad: &str) {
        assert!(bad.parse::<ThinMessage>().is_err(), "accepted {bad:?}");
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
        log: ChildPath,
        dmsetup: Dmsetup,
    }

    impl Fake {
        fn new(table: &str, failing_message: &str) -> Self {
            Self::with_tables(&[("*", table)], failing_message)
        }

        fn with_tables(tables: &[(&str, &str)], failing_message: &str) -> Self {
            let dir = TempDir::new().unwrap();
            let log = dir.child("calls");
            let bin = dir.child("dmsetup");
            let tables: String = tables
                .iter()
                .map(|(device, table)| format!("      {device}) printf '%b\\n' '{table}' ;;\n"))
                .collect();
            let script = format!(
                "#!/bin/sh\n\
                 printf '%s\\n' \"$*\" >> '{log}'\n\
                 case \"$1\" in\n\
                   table) case \"$2\" in\n{tables}    esac ;;\n\
                   info) printf '253:1\\n' ;;\n\
                   message) [ \"$4\" = '{failing_message}' ] && exit 1 ;;\n\
                 esac\n\
                 exit 0\n",
                log = log.display(),
            );
            bin.write_str(&script).unwrap();
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

    fn snapshot_of_id_2(r: &Result<Thin<Inactive>, SnapshotError>) -> bool {
        r.as_ref()
            .is_ok_and(|snap| snap.id() == ThinId::new(2).unwrap())
    }

    fn create_snap_failed(r: &Result<Thin<Inactive>, SnapshotError>) -> bool {
        matches!(r, Err(SnapshotError::CreateSnap(_)))
    }

    #[rstest]
    #[case::linear("0 100 linear 7:0 0")]
    #[case::thin("0 100 thin /dev/mapper/hyper-pool 1")]
    #[case::empty("")]
    fn thin_pool_refuses_a_device_that_is_not_a_pool_as_root(#[case] table: &str) {
        if !is_root() {
            eprintln!("SKIP thin_pool_refuses: needs root to own the fake dmsetup");
            return;
        }
        let fake = Fake::new(table, "");
        let got = fake.dmsetup.thin_pool(&name("hyper-x"));
        assert_matches!(got, Err(ThinPoolError::NotAThinPool { .. }));
        assert_eq!(fake.calls(), ["table hyper-x"]);
    }

    #[rstest]
    #[case::create_snap_succeeds("", snapshot_of_id_2)]
    #[case::create_snap_fails("create_snap 2 1", create_snap_failed)]
    fn snapshot_always_resumes_the_origin_as_root(
        #[case] failing_message: &str,
        #[case] expected: fn(&Result<Thin<Inactive>, SnapshotError>) -> bool,
    ) {
        if !is_root() {
            eprintln!("SKIP snapshot_always_resumes: needs root to own the fake dmsetup");
            return;
        }
        let fake = Fake::new(POOL_TABLE, failing_message);
        let pool = fake.dmsetup.thin_pool(&name("hyper-pool")).unwrap();
        let active = pool
            .create_thin(ThinId::new(1).unwrap())
            .unwrap()
            .activate(&name("hyper-vol"), 100, None)
            .unwrap();

        let got = active.snapshot(ThinId::new(2).unwrap());

        assert!(expected(&got), "{got:?}");
        assert_eq!(
            fake.calls(),
            [
                "table hyper-pool",
                "message hyper-pool 0 create_thin 1",
                "create hyper-vol --table 0 100 thin /dev/mapper/hyper-pool 1",
                "suspend hyper-vol",
                "message hyper-pool 0 create_snap 2 1",
                "resume hyper-vol",
            ]
        );
    }

    #[rstest]
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

    #[rstest]
    fn open_thin_reads_the_id_from_the_live_table_as_root() {
        if !is_root() {
            eprintln!("SKIP open_thin: needs root to own the fake dmsetup");
            return;
        }
        let fake = Fake::with_tables(
            &[
                ("hyper-pool", POOL_TABLE),
                ("hyper-vol", "0 100 thin 253:1 7 253:4"),
            ],
            "",
        );
        let pool = fake.dmsetup.thin_pool(&name("hyper-pool")).unwrap();

        let snap = pool
            .open_thin(&name("hyper-vol"))
            .unwrap()
            .snapshot(ThinId::new(8).unwrap())
            .unwrap();

        assert_eq!(snap.id(), ThinId::new(8).unwrap());
        assert_eq!(
            fake.calls()[1..],
            [
                "table hyper-vol",
                "info -c --noheadings -o major,minor hyper-pool",
                "suspend hyper-vol",
                "message hyper-pool 0 create_snap 8 7",
                "resume hyper-vol",
            ]
        );
    }

    #[rstest]
    #[case::thin_of_another_pool("0 100 thin 253:9 7")]
    #[case::linear("0 100 linear 7:0 0")]
    #[case::pool_itself(POOL_TABLE)]
    #[case::two_segments("0 100 thin 253:1 7\\n100 100 thin 253:1 8")]
    #[case::no_id("0 100 thin 253:1")]
    #[case::absent("")]
    fn open_thin_refuses_anything_but_a_thin_of_this_pool_as_root(#[case] table: &str) {
        if !is_root() {
            eprintln!("SKIP open_thin refusal: needs root to own the fake dmsetup");
            return;
        }
        let fake = Fake::with_tables(&[("hyper-pool", POOL_TABLE), ("hyper-vol", table)], "");
        let pool = fake.dmsetup.thin_pool(&name("hyper-pool")).unwrap();

        assert_matches!(
            pool.open_thin(&name("hyper-vol")),
            Err(OpenThinError::NotAThin { .. })
        );
    }

    #[rstest]
    #[case::not_a_number("0 100 thin 253:1 x")]
    #[case::past_24_bits("0 100 thin 253:1 16777216")]
    fn open_thin_refuses_an_invalid_id_as_root(#[case] table: &str) {
        if !is_root() {
            eprintln!("SKIP open_thin id: needs root to own the fake dmsetup");
            return;
        }
        let fake = Fake::with_tables(&[("hyper-pool", POOL_TABLE), ("hyper-vol", table)], "");
        let pool = fake.dmsetup.thin_pool(&name("hyper-pool")).unwrap();

        assert_matches!(
            pool.open_thin(&name("hyper-vol")),
            Err(OpenThinError::Id(_))
        );
    }
}
