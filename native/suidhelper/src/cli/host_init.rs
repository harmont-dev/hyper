// TODO(markovejnovic): This is slop and should be removed when networking is re-done.
use crate::cli::Op;
use crate::network::{self, host_init::HostInitError};
use hyperrs_process::privilege::Unprivileged;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostInit {}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum HostInitOut {
    HostReady,
}

impl Op for HostInit {
    type Output = HostInitOut;
    type Error = HostInitError;

    fn run(self, mut token: Unprivileged) -> Result<HostInitOut, HostInitError> {
        network::host_init(&mut token)?;
        Ok(HostInitOut::HostReady)
    }
}
