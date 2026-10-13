use std::io;

use nix::mount::{mount, MsFlags};

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
