use crate::cli::Op;
use hyperrs_process::privilege::Unprivileged;
use serde::{Deserialize, Serialize};
use std::convert::Infallible;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Version {}

#[derive(Serialize)]
pub struct VersionOut {
    version: &'static str,
    checksum_blake3: String,
}

impl Op for Version {
    type Output = VersionOut;
    type Error = Infallible;

    fn run(self, _token: Unprivileged) -> Result<VersionOut, Infallible> {
        Ok(VersionOut {
            version: env!("CARGO_PKG_VERSION"),
            checksum_blake3: hyperrs_elfsum::checksum!().hex(),
        })
    }
}
