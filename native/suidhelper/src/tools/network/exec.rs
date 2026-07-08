//! Shared execution of an [`args::Command`] sequence: resolve each command's
//! binary via `resolve`, spawn it with a cleared environment, and stop at the
//! first non-zero exit. This is the whole privileged window for every network
//! op — `prepare`, `teardown`, and `host_init` differ only in which commands
//! they hand to [`run_all`].
use super::args::{Command, Which};
use std::path::Path;
use std::process::Command as Proc;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum Error {
    #[error("running {bin:?} {argv:?}: {source}")]
    Spawn {
        bin: Which,
        argv: Vec<String>,
        #[source]
        source: std::io::Error,
    },
    #[error("{bin:?} {argv:?} failed: {stderr}")]
    Failed {
        bin: Which,
        argv: Vec<String>,
        stderr: String,
    },
}

pub(super) fn run_all<'a>(
    commands: &[Command],
    resolve: impl Fn(Which) -> &'a Path,
) -> Result<(), Error> {
    for command in commands {
        let output = Proc::new(resolve(command.bin))
            .args(&command.argv)
            .env_clear()
            .output()
            .map_err(|source| Error::Spawn {
                bin: command.bin,
                argv: command.argv.clone(),
                source,
            })?;

        if !output.status.success() {
            return Err(Error::Failed {
                bin: command.bin,
                argv: command.argv.clone(),
                stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
            });
        }
    }
    Ok(())
}
