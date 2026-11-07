use crate::config::Config;
use hyperrs_process::privilege::{PrivilegeError, Unprivileged};
use serde::Serialize;
use std::path::PathBuf;

#[derive(Serialize)]
pub struct SysTest {
    sys_test: &'static str,
    hyper_base: PathBuf,
}

pub fn run(token: &mut Unprivileged) -> Result<SysTest, PrivilegeError> {
    drop(token.elevate()?);
    Ok(SysTest {
        sys_test: "ok",
        hyper_base: Config::get().hyper_base().as_path().to_path_buf(),
    })
}
