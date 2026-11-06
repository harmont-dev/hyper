use hyperrs_linux::dm::{DmName, InvalidDmName, ParseDmDeviceError};
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

pub fn require_hyper(name: &DmName) -> Result<(), NameError> {
    if name.as_os_str().as_encoded_bytes().starts_with(HYPER_PREFIX.as_bytes()) {
        Ok(())
    } else {
        Err(NameError::NotHyper(name.clone()))
    }
}

pub fn parse_dm_name(s: &str) -> Result<DmName, NameError> {
    let name: DmName = s.parse()?;
    require_hyper(&name)?;
    Ok(name)
}

pub fn parse_dm_device(s: &str) -> Result<DmName, NameError> {
    let name = DmName::from_device_path(s)?;
    require_hyper(&name)?;
    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::{parse_dm_device, parse_dm_name, NameError};
    use proptest::prelude::*;
    use std::path::Path;

    proptest! {
        #[test]
        fn dm_name_accepts_every_valid_hyper_name(suffix in "[0-9A-Za-z#+.:=@_-]{0,32}") {
            let s = format!("hyper-{suffix}");
            prop_assert_eq!(parse_dm_name(&s).unwrap().to_string(), s);
        }

        #[test]
        fn dm_name_refuses_valid_names_we_do_not_own(s in "[0-9A-Za-z#+.:=@_][0-9A-Za-z#+.:=@_-]{0,32}") {
            prop_assume!(!s.starts_with("hyper-") && !matches!(s.as_str(), "." | ".." | "control"));
            prop_assert!(matches!(parse_dm_name(&s), Err(NameError::NotHyper(_))));
        }

        #[test]
        fn dm_name_refuses_hyper_names_the_kernel_would_reject(pre in "[a-z]{0,8}", post in "[a-z]{0,8}") {
            let s = format!("hyper-{pre}/{post}");
            prop_assert!(matches!(parse_dm_name(&s), Err(NameError::Invalid(_))));
        }

        #[test]
        fn dm_device_accepts_hyper_mapper_paths_and_preserves_them(suffix in "[0-9A-Za-z#+.:=@_-]{0,32}") {
            let s = format!("/dev/mapper/hyper-{suffix}");
            let path = parse_dm_device(&s).unwrap().path();
            prop_assert_eq!(path.as_path(), Path::new(&s));
        }

        #[test]
        fn dm_device_refuses_mapper_names_we_do_not_own(name in "[a-z][a-z0-9._-]{0,12}") {
            prop_assume!(!name.starts_with("hyper-") && name != "control");
            let s = format!("/dev/mapper/{name}");
            prop_assert!(matches!(parse_dm_device(&s), Err(NameError::NotHyper(_))));
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
                parse_dm_device(bad).is_err(),
                "parse_dm_device accepted {bad:?}"
            );
        }
    }
}
