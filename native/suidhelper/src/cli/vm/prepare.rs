use super::teardown;
use crate::cli::DispatchError;
use crate::network;
use clap::Args;
use hyperrs_firecracker::VmId;
use hyperrs_process::privilege::Unprivileged;

#[derive(Args)]
pub struct PrepareArgs {
    #[arg(long)]
    id: VmId,
    #[arg(long)]
    uid: u32,
}

pub fn run(
    PrepareArgs { id, uid }: PrepareArgs,
    token: &mut Unprivileged,
) -> Result<(), DispatchError> {
    teardown::run(&id, Some(uid), token)?;
    if network::enabled() {
        network::prepare(&id, uid, token).map_err(DispatchError::tool)?;
    }
    Ok(())
}
