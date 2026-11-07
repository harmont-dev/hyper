// SPDX-License-Identifier: MIT
pub mod grant;
pub mod launch;
pub mod prepare;
pub mod stage;
pub mod teardown;

use serde::Serialize;

pub const API_SOCKET: &str = "api.socket";
pub const VSOCK_SOCKET: &str = "vsock.sock";

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum VmOut {
    Prepared,
    Staged,
    Granted,
    Pending,
    ToreDown,
}
