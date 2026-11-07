// TODO(markovejnovic): This is slop and should be removed when networking is re-done.
use crate::cli::Op;
use crate::config::Config;
use crate::network::{self, host_init::HostInitError};
use hyperrs_process::privilege::Unprivileged;
use serde::{Deserialize, Serialize};
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
    type Error = HostInitError;

    fn run(self, mut token: Unprivileged) -> Result<HostInitOut, HostInitError> {
        network::host_init::HostInit::new()?.run(&mut token)?;
        Ok(HostInitOut::HostReady {
            hyper_base: Config::get().hyper_base().as_path().to_path_buf(),
        })
    }
}
