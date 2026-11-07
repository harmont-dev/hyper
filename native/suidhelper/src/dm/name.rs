use hyperrs_linux::dm::{DmName, DmTable, InvalidDmName, ParseDmDeviceError};
use std::ffi::OsStr;
use std::str::FromStr;
use thiserror::Error as ThisError;

const HYPER_PREFIX: &str = "hyper-";

#[derive(Debug, ThisError)]
pub enum NameError {
    #[error(transparent)]
    Invalid(#[from] InvalidDmName),
    #[error(transparent)]
    Device(#[from] ParseDmDeviceError),
    #[error("dm device name must start with `{HYPER_PREFIX}`: {0}")]
    NotHyper(DmName),
}

#[derive(Debug, Clone, PartialEq, Eq, derive_more::Display, derive_more::Deref)]
pub struct HyperDmName(DmName);

impl HyperDmName {
    pub fn from_device_path(path: &str) -> Result<Self, NameError> {
        DmName::from_device_path(path)?.try_into()
    }

    pub fn check_table(table: &DmTable) -> Result<(), NameError> {
        table
            .devices()
            .try_for_each(|dev| Self::try_from(dev.clone()).map(drop))
    }
}

impl TryFrom<DmName> for HyperDmName {
    type Error = NameError;

    fn try_from(name: DmName) -> Result<Self, Self::Error> {
        let raw: &OsStr = name.as_ref();
        if raw.as_encoded_bytes().starts_with(HYPER_PREFIX.as_bytes()) {
            Ok(Self(name))
        } else {
            Err(NameError::NotHyper(name))
        }
    }
}

impl FromStr for HyperDmName {
    type Err = NameError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        s.parse::<DmName>()?.try_into()
    }
}

#[cfg(test)]
mod tests {
    use super::{HyperDmName, NameError};
    use hyperrs_linux::dm::DmTable;
    use proptest::prelude::*;
    use rstest::rstest;
    use std::assert_matches;
    use test_strategy::proptest;

    #[proptest]
    fn every_valid_hyper_name_is_accepted(#[strategy("[0-9A-Za-z#+.:=@_-]{0,32}")] suffix: String) {
        let s = format!("hyper-{suffix}");
        prop_assert_eq!(s.parse::<HyperDmName>().unwrap().to_string(), s.clone());
        let dev = format!("/dev/mapper/{s}");
        prop_assert_eq!(HyperDmName::from_device_path(&dev).unwrap().to_string(), s);
    }

    #[proptest]
    fn a_name_we_do_not_own_is_refused_everywhere(
        #[strategy("[0-9A-Za-z#+.:=@_][0-9A-Za-z#+.:=@_-]{0,32}")] name: String,
    ) {
        prop_assume!(
            !name.starts_with("hyper-") && !matches!(name.as_str(), "." | ".." | "control")
        );
        let dev = format!("/dev/mapper/{name}");
        assert_matches!(name.parse::<HyperDmName>(), Err(NameError::NotHyper(_)));
        assert_matches!(
            HyperDmName::from_device_path(&dev),
            Err(NameError::NotHyper(_))
        );
        for table in [
            format!("0 8 linear {dev} 0"),
            format!("0 8 snapshot {dev} /srv/hyper/cow P 8"),
            format!("0 8 thin {dev} 1"),
            format!("0 8 thin /dev/mapper/hyper-pool 1 {dev}"),
        ] {
            let table: DmTable = table.parse().unwrap();
            assert_matches!(
                HyperDmName::check_table(&table),
                Err(NameError::NotHyper(_)),
                "accepted {table}"
            );
        }
    }

    #[rstest]
    #[case::linear_over_file("0 100 linear /srv/hyper/layers/base.img 0")]
    #[case::linear_over_hyper_device("0 100 linear /dev/mapper/hyper-img 0")]
    #[case::snapshot_of_hyper_device(
        "0 100 snapshot /dev/mapper/hyper-img /srv/hyper/scratch/cow.img P 8"
    )]
    #[case::thin_pool_over_files(
        "0 100 thin-pool /srv/hyper/scratch/meta /srv/hyper/scratch/data 128 1024"
    )]
    #[case::thin_with_hyper_origin("0 100 thin /dev/mapper/hyper-pool 0 /dev/mapper/hyper-orig")]
    #[case::thin_with_file_origin("0 100 thin /dev/mapper/hyper-pool 0 /srv/hyper/layers/base.img")]
    fn check_table_accepts_tables_over_hyper_devices(#[case] table: &str) {
        let table: DmTable = table.parse().unwrap();
        assert!(HyperDmName::check_table(&table).is_ok(), "rejected {table}");
    }
}
