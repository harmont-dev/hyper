use hyper_guest_agent::init::{resolver_from_cmdline, MOUNTS};
use std::net::Ipv4Addr;
use std::path::Path;

// A filesystem mounted at a nested target is only reachable once its parent
// filesystem is mounted -- /sys/fs/cgroup lives inside sysfs, so mounting it
// before /sys silently leaves the guest with no cgroup hierarchy and dockerd
// refuses to start. Ordering is load-bearing, not cosmetic.
#[test]
fn nested_targets_are_mounted_after_their_parent() {
    for (i, (_, target, _, _)) in MOUNTS.iter().enumerate() {
        for (j, (_, other, _, _)) in MOUNTS.iter().enumerate() {
            if i != j && Path::new(target).starts_with(other) {
                assert!(
                    j < i,
                    "{target} is nested under {other} but is mounted before it"
                );
            }
        }
    }
}

#[test]
fn resize_command_targets_the_root_device_and_is_absolute() {
    // The writable volume is created at the instance type's disk size, but a
    // larger block device does not move the filesystem's superblock -- without
    // growing it the guest still sees a filesystem the size of the image it
    // booted from, and Docker cannot pull anything into it.
    //
    // PID 1 runs with a near-empty environment and no PATH, so a bare
    // `resize2fs` would not resolve.
    let (program, args) = hyper_guest_agent::init::resize_root_command();

    assert!(
        program.starts_with('/'),
        "PID 1 has no PATH to resolve a bare command name against"
    );
    assert!(program.ends_with("resize2fs"));
    assert_eq!(args, vec!["/dev/vda"]);
}

#[test]
fn cgroup2_is_mounted_so_container_runtimes_can_start() {
    assert!(
        MOUNTS
            .iter()
            .any(|(_, target, fstype, _)| *target == "/sys/fs/cgroup" && *fstype == "cgroup2"),
        "guests run container runtimes, which refuse to start without a cgroup hierarchy"
    );
}

#[test]
fn run_is_a_private_tmpfs_on_every_guest_boot() {
    assert!(
        MOUNTS.iter().any(|(src, target, fstype, options)| {
            *src == "tmpfs"
                && *target == "/run"
                && *fstype == "tmpfs"
                && *options == Some("mode=755")
        }),
        "forked disks retain durable Docker data, but runtime sockets and PID files must start fresh"
    );
}

#[test]
fn present_among_other_params() {
    let cmdline = "reboot=k panic=1 hyper.resolver=1.1.1.1 ip=172.30.0.2::172.30.0.1:255.255.255.252::eth0:off";
    assert_eq!(
        resolver_from_cmdline(cmdline),
        Some(Ipv4Addr::new(1, 1, 1, 1))
    );
}

#[test]
fn absent_is_none() {
    let cmdline = "reboot=k panic=1 ip=172.30.0.2::172.30.0.1:255.255.255.252::eth0:off";
    assert_eq!(resolver_from_cmdline(cmdline), None);
}

#[test]
fn empty_cmdline_is_none() {
    assert_eq!(resolver_from_cmdline(""), None);
}

#[test]
fn empty_value_is_none() {
    assert_eq!(resolver_from_cmdline("hyper.resolver= ip=foo"), None);
}

#[test]
fn non_ipv4_value_is_none() {
    assert_eq!(resolver_from_cmdline("hyper.resolver=not-an-ip"), None);
}

#[test]
fn first_of_multiple_tokens_wins() {
    let cmdline = "hyper.resolver=1.1.1.1 hyper.resolver=8.8.8.8";
    assert_eq!(
        resolver_from_cmdline(cmdline),
        Some(Ipv4Addr::new(1, 1, 1, 1))
    );
}

#[test]
fn first_of_multiple_tokens_wins_among_other_params() {
    let cmdline = "a hyper.resolver=1.1.1.1 b hyper.resolver=8.8.8.8 c";
    assert_eq!(
        resolver_from_cmdline(cmdline),
        Some(Ipv4Addr::new(1, 1, 1, 1))
    );
}

// Regression: split_whitespace() + strip_prefix() requires the param to be its
// own whitespace-delimited token, not merely a substring anywhere on the
// cmdline. A future refactor to `cmdline.contains("hyper.resolver=")` would
// match this look-alike token and could point the guest at an attacker
// resolver embedded in an unrelated kernel param — that must never happen.
#[test]
fn prefixed_look_alike_token_is_not_matched() {
    assert_eq!(resolver_from_cmdline("xhyper.resolver=9.9.9.9"), None);
}

#[test]
fn suffixed_look_alike_key_is_not_matched() {
    assert_eq!(resolver_from_cmdline("hyper.resolverX=1.1.1.1"), None);
}
