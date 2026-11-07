use crate::cli::Op;
use crate::config::Config;
use hyperrs_process::privilege::Unprivileged;
use serde::{Deserialize, Serialize};
use std::convert::Infallible;
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostInit {}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum HostInitOut {
    HostReady { hyper_base: PathBuf },
}

impl Op for HostInit {
    type Output = HostInitOut;
    type Error = Infallible;

    fn run(self, _token: Unprivileged) -> Result<HostInitOut, Infallible> {
        Ok(HostInitOut::HostReady {
            hyper_base: Config::get().hyper_base().as_path().to_path_buf(),
        })
    }
}
