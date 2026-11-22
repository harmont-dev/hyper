// SPDX-License-Identifier: MIT
pub mod claim;
pub mod firewall;
pub mod launch;
pub mod link;
pub mod teardown;

use hyperrs_fs::path::StrictComponent;
use serde::Serialize;

pub const API_SOCKET: &str = "api.socket";
pub const VSOCK_SOCKET: &str = "vsock.sock";
pub const GUEST_SOCKET: &str = "guest.sock";
pub const GUEST_LINK: &StrictComponent = StrictComponent::from_static("vsock.sock_1100");

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum VmOut {
    Claimed,
    Pending,
    Linked,
    ToreDown,
    FirewallSet,
}
