// SPDX-License-Identifier: MIT
//! The IP link: veth pair, TAP, routes, NAT and proxy NDP.

use super::Unimplemented;
use crate::cli::Op;
use hyperrs_firecracker::VmId;
use hyperrs_process::privilege::Unprivileged;
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetIpHostInit {}

#[expect(dead_code)]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetIpPrepare {
    id: VmId,
    uid: u32,
}

#[expect(dead_code)]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetIpTeardown {
    id: VmId,
}

impl Op for NetIpHostInit {
    type Output = ();
    type Error = Unimplemented;

    fn run(self, _token: Unprivileged) -> Result<(), Unimplemented> {
        Err(Unimplemented)
    }
}

impl Op for NetIpPrepare {
    type Output = ();
    type Error = Unimplemented;

    fn run(self, _token: Unprivileged) -> Result<(), Unimplemented> {
        Err(Unimplemented)
    }
}

impl Op for NetIpTeardown {
    type Output = ();
    type Error = Unimplemented;

    fn run(self, _token: Unprivileged) -> Result<(), Unimplemented> {
        Err(Unimplemented)
    }
}
