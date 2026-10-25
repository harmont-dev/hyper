// SPDX-License-Identifier: MIT
//! Networking commands.

pub mod ip;

use crate::cli::Op;
use hyperrs_firecracker::VmId;
use hyperrs_process::privilege::Unprivileged;
use serde::Deserialize;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("VM networking is unimplemented (pending the networking rewrite)")]
pub struct Unimplemented;

#[expect(dead_code)]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetPrepare {
    id: VmId,
}

#[expect(dead_code)]
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NetTeardown {
    id: VmId,
}

impl Op for NetPrepare {
    type Output = ();
    type Error = Unimplemented;

    fn run(self, _token: Unprivileged) -> Result<(), Unimplemented> {
        Err(Unimplemented)
    }
}

impl Op for NetTeardown {
    type Output = ();
    type Error = Unimplemented;

    fn run(self, _token: Unprivileged) -> Result<(), Unimplemented> {
        Err(Unimplemented)
    }
}
