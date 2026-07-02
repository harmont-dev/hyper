use std::io;

use nix::mount::{mount, MsFlags};
use nix::sys::wait::{waitpid, WaitPidFlag, WaitStatus};
use nix::unistd::Pid;
use tokio::signal::unix::{signal, SignalKind};

// As PID 1 nothing else mounts these; exec'd programs need /proc and /dev.
pub fn setup() -> io::Result<()> {
    let none: Option<&str> = None;
    let mounts = [
        ("proc", "/proc", "proc"),
        ("sysfs", "/sys", "sysfs"),
        ("devtmpfs", "/dev", "devtmpfs"),
    ];
    for (src, target, fstype) in mounts {
        std::fs::create_dir_all(target).ok();
        // Best-effort: a rootfs that already has one mounted (or lacks the dir)
        // must not abort the agent; a missing /proc only degrades exec'd tools.
        let _ = mount(Some(src), target, Some(fstype), MsFlags::empty(), none);
    }
    Ok(())
}

// Spawn a tokio task that waits for SIGCHLD and reaps all orphaned children.
//
// Must be called after the tokio runtime is running and BEFORE the server
// starts accepting connections, to avoid a race where a child exits between
// fork and handler registration.
//
// Using tokio::signal rather than a raw libc::signal handler is required:
// a raw handler would clobber tokio's own child-process tracking and break
// tokio::process (needed in Task 4).
pub fn spawn_reaper() {
    tokio::spawn(async move {
        let mut sigchld = match signal(SignalKind::child()) {
            Ok(s) => s,
            Err(_) => return,
        };
        loop {
            sigchld.recv().await;
            loop {
                match waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG)) {
                    Ok(WaitStatus::StillAlive) | Err(_) => break,
                    Ok(_) => {}
                }
            }
        }
    });
}
