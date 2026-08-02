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
    // Best-effort, after the mounts: the writable volume is created at the
    // instance type's disk size, but a larger block device does not move the
    // filesystem's superblock. Without this the guest sees a filesystem the
    // size of the image it booted from -- enough for the image and nothing
    // else, so a container runtime cannot pull into it.
    //
    // A failure only costs the guest its extra room, never boot: an image
    // already sized to its volume reports "nothing to do", and a guest without
    // resize2fs installed simply keeps what it has.
    let _ = grow_root();

    // Best-effort, run after /proc is mounted: the kernel's `ip=` autoconfig
    // sets the guest's address/route but never DNS, so BootSpec appends
    // `hyper.resolver=<ip>` to the cmdline for us to relay into resolv.conf. A
    // missing param or unwritable /etc only degrades DNS, never boot.
    let _ = write_resolv_conf();
    Ok(())
}

/// The command that grows the root filesystem to fill its block device.
///
/// Absolute because PID 1 runs with a near-empty environment and no `PATH`, so
/// a bare command name would not resolve. `/dev/vda` is what Firecracker
/// attaches the rootfs as (`root=/dev/vda`, appended to the boot args).
///
/// ext4 grows online, so this runs against the mounted root.
pub fn resize_root_command() -> (&'static str, Vec<&'static str>) {
    ("/usr/sbin/resize2fs", vec![ROOT_DEVICE])
}

const ROOT_DEVICE: &str = "/dev/vda";

fn grow_root() -> io::Result<()> {
    let (program, args) = resize_root_command();
    std::process::Command::new(program)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|_| ())
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
