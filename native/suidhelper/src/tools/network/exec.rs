//! Shared execution of an [`args::Command`] sequence: resolve each command's
//! binary via `resolve`, spawn it with a cleared environment, and stop at the
//! first non-zero exit — unless the command is marked `allow_failure`, in
//! which case its exit status is ignored and the sequence continues. This is
//! the whole privileged window for every network op — `prepare`, `teardown`,
//! and `host_init` differ only in which commands they hand to [`run_all`].
use super::args::{Command, Which};
use crate::util::setuid_privileged::Privileged;
use std::path::Path;
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
    #[error("{bin:?} {argv:?} exited {code}: stderr={stderr:?} stdout={stdout:?}")]
    Failed {
        bin: Which,
        argv: Vec<String>,
        code: String,
        stderr: String,
        stdout: String,
    },
}

pub(super) fn run_all<'a>(
    privileged: &Privileged,
    commands: &[Command],
    resolve: impl Fn(Which) -> &'a Path,
) -> Result<(), Error> {
    for command in commands {
        // `ip` and `nft` refuse to run under `AT_SECURE` — the setuid-like state
        // the kernel flags when a child is exec'd with `ruid != euid`. Our
        // privilege guard raises only euid to 0, leaving ruid at the caller, so
        // a plain child inherits that mismatch and nft exits 111 with no output
        // at all. `root_command` promotes the forked child to genuine root (all
        // of real/effective/saved uid == 0) just before exec, without touching
        // the parent's own privilege window.
        let mut proc = privileged.root_command(resolve(command.bin));
        proc.args(&command.argv).env_clear();

        let output = proc.output().map_err(|source| Error::Spawn {
            bin: command.bin,
            argv: command.argv.clone(),
            source,
        })?;

        if !output.status.success() && !command.allow_failure {
            return Err(Error::Failed {
                bin: command.bin,
                argv: command.argv.clone(),
                code: output
                    .status
                    .code()
                    .map_or_else(|| "signal".to_string(), |c| c.to_string()),
                stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
                stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
            });
        }
    }
    Ok(())
}
