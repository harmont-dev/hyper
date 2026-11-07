// SPDX-License-Identifier: MIT
pub mod grant;
pub mod launch;
pub mod prepare;
pub mod stage;
pub mod teardown;

use hyperrs_fs::path::StrictComponent;
use serde::Serialize;

pub const API_SOCKET: &StrictComponent = StrictComponent::from_static("api.socket");
pub const VSOCK_SOCKET: &StrictComponent = StrictComponent::from_static("vsock.sock");

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum VmOut {
    Prepared,
    Staged,
    Granted,
    ToreDown,
}
