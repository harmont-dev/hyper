use super::teardown::{self, TeardownError};
use super::VmOut;
use crate::cli::Op;
use crate::network;
use crate::network::prepare::NetworkPrepareError;
use hyperrs_firecracker::VmId;
use hyperrs_process::privilege::Unprivileged;
use serde::Deserialize;
use serde_with::{serde_as, DisplayFromStr};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum PrepareError {
    #[error(transparent)]
    Teardown(#[from] TeardownError),
    #[error(transparent)]
    Network(#[from] NetworkPrepareError),
}

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Prepare {
    #[serde_as(as = "DisplayFromStr")]
    id: VmId,
    uid: u32,
}

impl Op for Prepare {
    type Output = VmOut;
    type Error = PrepareError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, PrepareError> {
        let Prepare { id, uid } = self;
        teardown::teardown(&id, Some(uid), &mut token)?;
        if network::enabled() {
            network::prepare(&id, uid, &mut token)?;
        }
        Ok(VmOut::Prepared)
    }
}
