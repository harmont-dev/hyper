use super::{teardown, VmOut};
use crate::cli::{DispatchError, Op};
use crate::network;
use hyperrs_firecracker::VmId;
use hyperrs_process::privilege::Unprivileged;
use serde::Deserialize;
use serde_with::{serde_as, DisplayFromStr};

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
    type Error = DispatchError;

    fn run(self, mut token: Unprivileged) -> Result<VmOut, DispatchError> {
        let Prepare { id, uid } = self;
        teardown::teardown(&id, Some(uid), &mut token)?;
        if network::enabled() {
            network::prepare(&id, uid, &mut token).map_err(DispatchError::tool)?;
        }
        Ok(VmOut::Prepared)
    }
}
