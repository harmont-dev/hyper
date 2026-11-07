use crate::cli::Op;
use crate::config::Config;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SysTest {}

#[derive(Serialize)]
pub struct SysTestOut {
    sys_test: &'static str,
    hyper_base: PathBuf,
}

impl Op for SysTest {
    type Output = SysTestOut;
    type Error = PrivilegeError;

    fn run(self, mut token: Unprivileged) -> Result<SysTestOut, PrivilegeError> {
        drop(token.elevate()?);
        Ok(SysTestOut {
            sys_test: "ok",
            hyper_base: Config::get().hyper_base().as_path().to_path_buf(),
        })
    }
}
