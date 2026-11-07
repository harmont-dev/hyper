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
    use std::path::Path;

    proptest! {
        #[test]
        fn dm_name_accepts_every_valid_hyper_name(suffix in "[0-9A-Za-z#+.:=@_-]{0,32}") {
            let s = format!("hyper-{suffix}");
            prop_assert_eq!(s.parse::<HyperDmName>().unwrap().to_string(), s);
        }

        #[test]
        fn dm_name_refuses_valid_names_we_do_not_own(s in "[0-9A-Za-z#+.:=@_][0-9A-Za-z#+.:=@_-]{0,32}") {
            prop_assume!(!s.starts_with("hyper-") && !matches!(s.as_str(), "." | ".." | "control"));
            prop_assert!(matches!(s.parse::<HyperDmName>(), Err(NameError::NotHyper(_))));
        }

        #[test]
        fn dm_name_refuses_hyper_names_the_kernel_would_reject(pre in "[a-z]{0,8}", post in "[a-z]{0,8}") {
            let s = format!("hyper-{pre}/{post}");
            prop_assert!(matches!(s.parse::<HyperDmName>(), Err(NameError::Invalid(_))));
        }

        #[test]
        fn dm_device_accepts_hyper_mapper_paths_and_preserves_them(suffix in "[0-9A-Za-z#+.:=@_-]{0,32}") {
            let s = format!("/dev/mapper/hyper-{suffix}");
            let path = HyperDmName::from_device_path(&s).unwrap().path();
            prop_assert_eq!(path.as_path(), Path::new(&s));
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
                let table: DmTable = table.parse().unwrap();
                prop_assert!(
                    matches!(HyperDmName::check_table(&table), Err(NameError::NotHyper(_))),
                    "accepted {}", table
                );
            }
        }

        #[test]
        fn dm_device_refuses_mapper_names_we_do_not_own(name in "[a-z][a-z0-9._-]{0,12}") {
            prop_assume!(!name.starts_with("hyper-") && name != "control");
            let s = format!("/dev/mapper/{name}");
            prop_assert!(matches!(HyperDmName::from_device_path(&s), Err(NameError::NotHyper(_))));
        }
    }

    #[test]
    fn dm_device_rejects_known_attack_strings() {
        for bad in [
            "/dev/sda",
            "/dev/loop0",
            "/dev/mapper/hyper-x/../../sda",
            "/dev/mapper/hyper-x/",
            "/dev/mapper/cryptroot",
            "/dev/mapper/control",
            "../dev/mapper/hyper-x",
            "dev/mapper/hyper-x",
            "hyper-x",
        ] {
            assert!(
                HyperDmName::from_device_path(bad).is_err(),
                "accepted {bad:?}"
            );
        }
    }

    #[test]
    fn check_table_accepts_tables_over_hyper_devices() {
        for s in [
            "0 100 linear /srv/hyper/layers/base.img 0",
            "0 100 linear /dev/mapper/hyper-img 0",
            "0 100 snapshot /dev/mapper/hyper-img /srv/hyper/scratch/cow.img P 8",
            "0 100 thin-pool /srv/hyper/scratch/meta /srv/hyper/scratch/data 128 1024",
            "0 100 thin /dev/mapper/hyper-pool 0 /dev/mapper/hyper-orig",
            "0 100 thin /dev/mapper/hyper-pool 0 /srv/hyper/layers/base.img",
        ] {
            let table: DmTable = s.parse().unwrap();
            assert!(HyperDmName::check_table(&table).is_ok(), "rejected {s:?}");
        }
    }
}
