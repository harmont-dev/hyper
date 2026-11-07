use super::{teardown, VmOut};
use crate::cli::DispatchError;
use crate::network;
use hyperrs_firecracker::VmId;
use hyperrs_process::privilege::Unprivileged;
use serde::Deserialize;
use serde_with::{serde_as, DisplayFromStr};

#[serde_as]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrepareArgs {
    #[serde_as(as = "DisplayFromStr")]
    id: VmId,
    uid: u32,
}

pub fn run(
    PrepareArgs { id, uid }: PrepareArgs,
    token: &mut Unprivileged,
) -> Result<VmOut, DispatchError> {
    teardown::teardown(&id, Some(uid), token)?;
    if network::enabled() {
        network::prepare(&id, uid, token).map_err(DispatchError::tool)?;
    }
    Ok(VmOut::Prepared)
}
