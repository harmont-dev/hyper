use crate::cli::OpError;
use crate::network::{self, host_init::HostInitError};
use hyperrs_process::privilege::Unprivileged;
use serde::Serialize;

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum HostInitOut {
    HostReady,
}

pub fn run(token: &mut Unprivileged) -> Result<HostInitOut, HostInitError> {
    network::host_init(token)?;
    Ok(HostInitOut::HostReady)
}

impl OpError for HostInitError {}
