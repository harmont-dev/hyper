// SPDX-License-Identifier: MIT

use crate::net::IfName;
use derive_more::Display;
use hyperrs_fs::dir::SafeDir;
use hyperrs_fs::file::{self, Any, IsRegularFile, OpenFlags, SafeFile};
use hyperrs_fs::path::{SafePath, StrictComponent};
use nix::sys::stat::Mode;
use std::io::{self, Write};
use std::path::PathBuf;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
pub enum SysctlError {
    #[error("opening /proc/sys: {0}")]
    Root(#[source] file::ValidationError),
    #[error("opening sysctl {0}: {1}")]
    Open(SysctlKey, #[source] file::ValidationError),
    #[error("writing sysctl {0}: {1}")]
    Write(SysctlKey, #[source] io::Error),
}

/// A path under `/proc/sys`.
#[derive(Debug, Clone, PartialEq, Eq, Display)]
#[display("{}", _0.display())]
pub struct SysctlKey(PathBuf);

impl SysctlKey {
    fn child(self, segment: &StrictComponent) -> Self {
        Self(self.0.join(segment.as_path()))
    }
}

/// The root of the `/proc/sys` tree.
pub struct Sysctl;

impl Sysctl {
    /// `net/`.
    pub fn net() -> Net {
        Net(SysctlKey(PathBuf::from("net")))
    }
}

/// `net/`.
pub struct Net(SysctlKey);

impl Net {
    /// `net/ipv4/`.
    pub fn ipv4(self) -> Ipv4 {
        Ipv4(self.0.child(StrictComponent::from_static("ipv4")))
    }

    /// `net/ipv6/`.
    pub fn ipv6(self) -> Ipv6 {
        Ipv6(self.0.child(StrictComponent::from_static("ipv6")))
    }
}

/// `net/ipv4/`.
pub struct Ipv4(SysctlKey);

impl Ipv4 {
    /// `net/ipv4/ip_forward`.
    pub fn ip_forward(self, on: bool) -> Setting {
        Setting::flag(self.0.child(StrictComponent::from_static("ip_forward")), on)
    }
}

/// `net/ipv6/`.
pub struct Ipv6(SysctlKey);

impl Ipv6 {
    /// `net/ipv6/conf/all/`.
    pub fn conf_all(self) -> Ipv6Conf {
        self.conf_dir(StrictComponent::from_static("all"))
    }

    /// `net/ipv6/conf/default/`.
    pub fn conf_default(self) -> Ipv6Conf {
        self.conf_dir(StrictComponent::from_static("default"))
    }

    /// `net/ipv6/conf/<link>/`.
    pub fn conf(self, link: &IfName) -> Ipv6Conf {
        self.conf_dir(link.as_component())
    }

    fn conf_dir(self, dir: &StrictComponent) -> Ipv6Conf {
        Ipv6Conf(
            self.0
                .child(StrictComponent::from_static("conf"))
                .child(dir),
        )
    }
}

/// `net/ipv6/conf/<…>/`.
pub struct Ipv6Conf(SysctlKey);

impl Ipv6Conf {
    /// `net/ipv6/conf/<…>/forwarding`.
    pub fn forwarding(self, on: bool) -> Setting {
        Setting::flag(self.0.child(StrictComponent::from_static("forwarding")), on)
    }

    /// `net/ipv6/conf/<…>/proxy_ndp`.
    pub fn proxy_ndp(self, on: bool) -> Setting {
        Setting::flag(self.0.child(StrictComponent::from_static("proxy_ndp")), on)
    }
}

/// A sysctl and the value to give it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Setting {
    key: SysctlKey,
    value: &'static str,
}

impl Setting {
    fn flag(key: SysctlKey, on: bool) -> Self {
        Self {
            key,
            value: if on { "1" } else { "0" },
        }
    }

    /// Write the value in the calling thread's network namespace.
    pub fn write(&self) -> Result<(), SysctlError> {
        let root = SafeDir::open(SafePath::from_static::<"/proc/sys">(), OpenFlags::RDONLY)
            .map_err(SysctlError::Root)?;

        let mut file: SafeFile<IsRegularFile, Any, Any> = root
            .openat(&self.key.0, OpenFlags::WRONLY, Mode::empty())
            .map_err(|e| SysctlError::Open(self.key.clone(), e))?;

        file.write_all(self.value.as_bytes())
            .map_err(|e| SysctlError::Write(self.key.clone(), e))
    }
}

#[cfg(test)]
mod tests {
    use super::{Setting, Sysctl};
    use crate::net::netns::NetNs;
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use std::fs;

    struct ScratchNs(Option<NetNs>);

    impl ScratchNs {
        fn new(test: &str) -> Option<Self> {
            if !nix::unistd::geteuid().is_root() {
                eprintln!("SKIP {test}: needs root to create a network namespace");
                return None;
            }
            let name = format!("hyper-test-{}-{test}", std::process::id());
            Some(Self(Some(
                NetNs::create(name.as_str().try_into().unwrap()).unwrap(),
            )))
        }

        fn get(&self) -> &NetNs {
            self.0.as_ref().expect("the namespace lives until drop")
        }
    }

    impl Drop for ScratchNs {
        fn drop(&mut self) {
            if let Some(ns) = self.0.take() {
                let _ = ns.remove();
            }
        }
    }

    fn read(path: &str) -> String {
        fs::read_to_string(format!("/proc/sys/{path}"))
            .unwrap()
            .trim()
            .to_owned()
    }

    #[rstest]
    #[case::ipv4_forward("sysctl-v4-fwd", "net/ipv4/ip_forward", |on| Sysctl::net().ipv4().ip_forward(on))]
    #[case::ipv6_forwarding_all(
        "sysctl-v6-fwd-all",
        "net/ipv6/conf/all/forwarding",
        |on| Sysctl::net().ipv6().conf_all().forwarding(on),
    )]
    #[case::ipv6_forwarding_default(
        "sysctl-v6-fwd-default",
        "net/ipv6/conf/default/forwarding",
        |on| Sysctl::net().ipv6().conf_default().forwarding(on),
    )]
    #[case::ipv6_proxy_ndp_link(
        "sysctl-v6-proxy-ndp",
        "net/ipv6/conf/lo/proxy_ndp",
        |on| Sysctl::net().ipv6().conf(&"lo".parse().unwrap()).proxy_ndp(on),
    )]
    fn a_net_sysctl_changes_only_the_namespace_it_is_written_in_as_root(
        #[case] test: &str,
        #[case] path: &str,
        #[case] sysctl: fn(bool) -> Setting,
    ) {
        let Some(ns) = ScratchNs::new(test) else {
            return;
        };
        let host = read(path);
        let host_on = host == "1";
        let write_then_read = |on| {
            ns.get()
                .scoped(|| {
                    sysctl(on).write().unwrap();
                    read(path)
                })
                .unwrap()
        };

        let values = [write_then_read(host_on), write_then_read(!host_on)];

        let flipped = if host_on { "0" } else { "1" };
        assert_eq!(values, [host.as_str(), flipped]);
        assert_eq!(read(path), host);
    }
}
