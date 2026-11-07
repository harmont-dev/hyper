// SPDX-License-Identifier: MIT
pub mod claim;
pub mod launch;
pub mod teardown;

use serde::Serialize;

pub const API_SOCKET: &str = "api.socket";
pub const VSOCK_SOCKET: &str = "vsock.sock";

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum VmOut {
    Claimed,
    Pending,
    ToreDown,
}
