//! Shared execution of an [`args::Command`] sequence: resolve each command's
//! binary via `resolve`, spawn it with a cleared environment, and stop at the
//! first non-zero exit — unless the command is marked `allow_failure`, in
//! which case its exit status is ignored and the sequence continues. This is
//! the whole privileged window for every network op — `prepare`, `teardown`,
//! and `host_init` differ only in which commands they hand to [`run_all`].
use super::args::{Command, Which};
use crate::util::setuid_privileged::become_root_permanently;
use std::io;
use std::os::unix::process::CommandExt;
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
    commands: &[Command],
    resolve: impl Fn(Which) -> &'a Path,
) -> Result<(), Error> {
    for command in commands {
        let mut proc = Proc::new(resolve(command.bin));
        proc.args(&command.argv).env_clear();

        // `ip` and `nft` refuse to run under `AT_SECURE` — the setuid-like state
        // the kernel flags when a child is exec'd with `ruid != euid`. Our
        // privilege guard (`Privileged::acquire`) raises only euid to 0, leaving
        // ruid at the caller, so without this the child inherits that mismatch
        // and nft exits 111 with no output at all. Promote the child to genuine
        // root (all of real/effective/saved uid == 0) just before exec — the
        // same reason the jailer handoff uses `become_root_permanently`. This
        // runs in the forked child, so it never affects the parent's own
        // privilege window.
        //
        // SAFETY: `become_root_permanently` calls only async-signal-safe
        // setresuid/setresgid/setgroups syscalls and allocates nothing, which is
        // the contract `pre_exec` requires of the post-fork, pre-exec child.
        unsafe {
            proc.pre_exec(|| become_root_permanently().map_err(io::Error::other));
        }

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
