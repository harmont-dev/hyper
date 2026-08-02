use std::io;
use std::net::Ipv4Addr;

use nix::mount::{mount, MsFlags};

const RESOLVER_PARAM: &str = "hyper.resolver=";

/// Filesystems PID 1 mounts for the guest, in dependency order: a nested target
/// is only reachable once the filesystem it sits inside is mounted.
///
/// `/sys/fs/cgroup` is here because container runtimes refuse to start without
/// a cgroup hierarchy, and only PID 1 can mount it -- an exec'd program gets
/// EPERM, which `mount(8)` reports as the rather misleading "must be superuser
/// to use mount".
pub const MOUNTS: [(&str, &str, &str); 4] = [
    ("proc", "/proc", "proc"),
    ("sysfs", "/sys", "sysfs"),
    ("devtmpfs", "/dev", "devtmpfs"),
    ("cgroup2", "/sys/fs/cgroup", "cgroup2"),
];

// As PID 1 nothing else mounts these; exec'd programs need /proc and /dev.
pub fn setup() -> io::Result<()> {
    let none: Option<&str> = None;
    for (src, target, fstype) in MOUNTS {
        std::fs::create_dir_all(target).ok();
        // Best-effort: a rootfs that already has one mounted (or lacks the dir)
        // must not abort the agent; a missing /proc only degrades exec'd tools.
        let _ = mount(Some(src), target, Some(fstype), MsFlags::empty(), none);
    }
    // Best-effort, run after /proc is mounted: the kernel's `ip=` autoconfig
    // sets the guest's address/route but never DNS, so BootSpec appends
    // `hyper.resolver=<ip>` to the cmdline for us to relay into resolv.conf. A
    // missing param or unwritable /etc only degrades DNS, never boot.
    let _ = write_resolv_conf();
    Ok(())
}

/// Extracts the value of the `hyper.resolver=` token from a `/proc/cmdline`-style
/// space-separated string. `None` if the param is absent, has an empty value,
/// or the value isn't a valid IPv4 address. Where the same param repeats, the
/// first occurrence wins (matches kernel cmdline parsing conventions).
pub fn resolver_from_cmdline(cmdline: &str) -> Option<Ipv4Addr> {
    cmdline
        .split_whitespace()
        .find_map(|token| token.strip_prefix(RESOLVER_PARAM))
        .filter(|value| !value.is_empty())
        .and_then(|value| value.parse().ok())
}

fn write_resolv_conf() -> io::Result<()> {
    let cmdline = std::fs::read_to_string("/proc/cmdline")?;
    let Some(resolver) = resolver_from_cmdline(&cmdline) else {
        return Ok(());
    };
    std::fs::write("/etc/resolv.conf", format!("nameserver {resolver}\n"))
}
