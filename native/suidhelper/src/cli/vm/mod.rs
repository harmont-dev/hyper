// SPDX-License-Identifier: MIT
pub mod grant;
pub mod launch;
pub mod prepare;
pub mod stage;
pub mod teardown;

use crate::cli::{to_json, DispatchError};
use clap::Subcommand;
use hyperrs_fs::path::StrictComponent;
use hyperrs_process::privilege::Unprivileged;
use serde::Serialize;

pub const API_SOCKET: &StrictComponent = StrictComponent::from_static("api.socket");
pub const VSOCK_SOCKET: &StrictComponent = StrictComponent::from_static("vsock.sock");

#[derive(Subcommand)]
pub enum VmOp {
    Prepare(prepare::PrepareArgs),
    Launch(launch::LaunchArgs),
    Stage(stage::StageArgs),
    GrantApi(grant::GrantArgs),
    GrantVsock(grant::GrantArgs),
    Teardown(teardown::TeardownArgs),
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum VmOut {
    Prepared,
    Staged,
    Granted,
    ToreDown,
}

impl VmOp {
    pub fn run(self, mut token: Unprivileged) -> Result<serde_json::Value, DispatchError> {
        let out = match self {
            VmOp::Prepare(args) => {
                prepare::run(args, &mut token)?;
                VmOut::Prepared
            }
            VmOp::Launch(args) => launch::run(args, token),
            VmOp::Stage(args) => {
                stage::run(args, &mut token).map_err(DispatchError::tool)?;
                VmOut::Staged
            }
            VmOp::GrantApi(args) => {
                grant::run(&args, API_SOCKET, &mut token)?;
                VmOut::Granted
            }
            VmOp::GrantVsock(args) => {
                grant::run(&args, VSOCK_SOCKET, &mut token)?;
                VmOut::Granted
            }
            VmOp::Teardown(args) => {
                teardown::run(&args.id, args.uid, &mut token)?;
                VmOut::ToreDown
            }
        };
        to_json(out)
    }
}
