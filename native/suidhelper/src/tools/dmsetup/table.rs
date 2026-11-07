use super::backing::{BackingError, BackingFile};
use super::name::{HyperDmName, NameError};
use crate::config::Config;
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use hyperrs_linux::dm::{DmTable, ParseTableError};
use thiserror::Error as ThisError;

pub type FilePath = SafePathBuf<IsAbsolute, StrictComponents>;

const DEV_PREFIX: &str = "/dev/";

#[derive(Debug, ThisError)]
pub enum TableError {
    #[error(transparent)]
    Parse(#[from] ParseTableError),
    #[error(transparent)]
    Name(#[from] NameError),
    #[error("expected a backing file, got a device: {0}")]
    NotAFile(String),
    #[error(transparent)]
    Backing(#[from] BackingError),
}

pub fn parse_table(s: &str) -> Result<DmTable<FilePath>, TableError> {
    let table: DmTable<FilePath> = s.parse()?;
    table
        .devices()
        .try_for_each(|dev| HyperDmName::try_from(dev.clone()).map(drop))?;
    table.try_map(|file, _| {
        let path = file.as_path();
        if path.starts_with(DEV_PREFIX) {
            Err(TableError::NotAFile(path.display().to_string()))
        } else {
            Ok(file)
        }
    })
}

pub fn resolve_table(s: &str) -> Result<DmTable<BackingFile>, TableError> {
    let base = Config::get().hyper_base();
    Ok(parse_table(s)?.try_map(|path, _| BackingFile::open(path.as_path(), base))?)
}

#[cfg(test)]
mod tests {
    use super::parse_table;
    use proptest::prelude::*;

    #[test]
    fn accepts_hyper_tables_and_round_trips() {
        for s in [
            "0 100 linear /srv/hyper/layers/base.img 0",
            "0 100 linear /dev/mapper/hyper-img 0",
            "0 100 snapshot /srv/hyper/layers/base.img /srv/hyper/layers/delta.img P 8",
            "0 100 snapshot /dev/mapper/hyper-img /srv/hyper/scratch/cow.img P 8",
            "0 100 thin-pool /srv/hyper/scratch/meta /srv/hyper/scratch/data 128 1024",
            "0 100 thin /dev/mapper/hyper-pool 0",
            "0 100 thin /dev/mapper/hyper-pool 0 /dev/mapper/hyper-orig",
            "0 100 thin /dev/mapper/hyper-pool 0 /srv/hyper/layers/base.img",
            "0 100 thin /dev/mapper/hyper-pool 16777215",
        ] {
            let t = parse_table(s).unwrap_or_else(|e| panic!("rejected {s:?}: {e}"));
            assert_eq!(t.to_string(), s, "round-trip changed {s:?}");
        }
    }

    #[test]
    fn rejects_non_whitelisted_targets_and_devices() {
        for bad in [
            "0 100 crypt /dev/loop0 /srv/hyper/a",
            "0 100 linear /dev/sda 0",
            "0 100 linear /srv/hyper/a 8",
            "0 100 snapshot /dev/sda /srv/hyper/a P 8",
            "0 100 snapshot /dev/loop0 /dev/loop1 P 8",
            "0 100 snapshot /dev/loop0 srv/hyper/a P 8",
            "0 100 snapshot /dev/loop0 /srv/hyper/../a P 8",
            "0 100 snapshot /dev/loop0 /srv/hyper/a X 8",
            "1 100 snapshot /dev/loop0 /srv/hyper/a P 8",
            "0 100 snapshot /dev/loop0 /srv/hyper/a P",
            "0 100 thin-pool /dev/loop0 /srv/hyper/d 128 1024",
            "0 100 thin-pool /srv/hyper/m /dev/loop1 128 1024",
            "0 100 thin /dev/sda 0",
            "0 100 thin /srv/hyper/pool 0",
            "0 100 thin /dev/loop0 0",
            "0 100 thin /dev/mapper/other 0",
            "0 100 thin /dev/mapper/hyper-pool 16777216",
            "0 100 thin /dev/mapper/hyper-pool 0 /dev/sda",
            "0 100 thin /dev/mapper/hyper-pool 0 /dev/mapper/other",
            "0 100 thin /dev/mapper/hyper-pool 0 /dev/loop0 /dev/loop1",
            "0 100 linear /dev/mapper/other 0",
            "",
            "garbage",
        ] {
            assert!(parse_table(bad).is_err(), "parse_table accepted {bad:?}");
        }
    }

    proptest! {
        #[test]
        fn a_device_is_never_accepted_as_a_backing_file(rest in "[A-Za-z0-9._/-]{1,32}") {
            let dev = format!("/dev/{rest}");
            for table in [
                format!("0 8 snapshot /dev/mapper/hyper-img {dev} P 8"),
                format!("0 8 thin-pool {dev} /srv/hyper/data 128 0"),
                format!("0 8 thin-pool /srv/hyper/meta {dev} 128 0"),
            ] {
                prop_assert!(parse_table(&table).is_err(), "accepted {:?}", table);
            }
        }

        #[test]
        fn a_device_we_do_not_own_is_refused_in_every_device_slot(name in "[a-z][a-z0-9_]{0,12}") {
            prop_assume!(name != "control");
            let dev = format!("/dev/mapper/{name}");
            for table in [
                format!("0 8 linear {dev} 0"),
                format!("0 8 snapshot {dev} /srv/hyper/cow P 8"),
                format!("0 8 thin {dev} 1"),
                format!("0 8 thin /dev/mapper/hyper-pool 1 {dev}"),
            ] {
                prop_assert!(parse_table(&table).is_err(), "accepted {:?}", table);
            }
        }
    }
}
