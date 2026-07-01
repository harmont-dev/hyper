use std::io;

use nix::mount::{mount, MsFlags};
use nix::sys::signal::{signal, SigHandler, Signal};
use nix::sys::wait::{waitpid, WaitPidFlag};
use nix::unistd::Pid;

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
    unsafe {
        signal(Signal::SIGCHLD, SigHandler::Handler(reap))?;
    }
    Ok(())
}

// PID-1 duty: reap orphans a double-forking command reparents to us.
extern "C" fn reap(_: i32) {
    while let Ok(status) = waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG)) {
        if matches!(status, nix::sys::wait::WaitStatus::StillAlive) {
            break;
        }
    }
}
