//! The guest's IPv6 on `eth0`, from `hyper.ip6=` on the kernel command line.
//!
//! The kernel's `ip=` autoconfig brings `eth0` up with the guest's IPv4, but has no
//! IPv6 counterpart, so the host passes the guest's address here instead.

use hyperrs_linux::net::link::{AddrError, DuplicateAddrDetection, LinkError};
use hyperrs_linux::net::route::{Route, RouteError};
use hyperrs_linux::net::{IfName, IpNet, Ipv6Net, Rtnl, RtnlOpenError};
use std::io;
use std::net::Ipv6Addr;
use thiserror::Error as ThisError;

const IP6_PARAM: &str = "hyper.ip6=";
const GATEWAY: Ipv6Addr = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);

#[derive(Debug, ThisError)]
pub enum GuestNetError {
    #[error("reading /proc/cmdline: {0}")]
    Cmdline(#[source] io::Error),
    #[error(transparent)]
    Rtnl(#[from] RtnlOpenError),
    #[error(transparent)]
    Link(#[from] LinkError),
    #[error("{0} is missing")]
    MissingLink(IfName),
    #[error(transparent)]
    Addr(#[from] AddrError),
    #[error(transparent)]
    Route(#[from] RouteError),
}

/// The guest's IPv6 address, routed out of `eth0` via the host's `fe80::1`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GuestNet {
    addr: Ipv6Addr,
}

impl GuestNet {
    /// Read the address from `/proc/cmdline`; `None` when the host passed none.
    pub fn from_proc() -> Result<Option<Self>, GuestNetError> {
        let cmdline = std::fs::read_to_string("/proc/cmdline").map_err(GuestNetError::Cmdline)?;
        Ok(Self::from_cmdline(&cmdline))
    }

    /// Parse `hyper.ip6=<addr>` out of a kernel command line; the first occurrence wins.
    pub fn from_cmdline(cmdline: &str) -> Option<Self> {
        cmdline
            .split_whitespace()
            .find_map(|token| token.strip_prefix(IP6_PARAM))
            .and_then(|value| value.parse().ok())
            .map(|addr| Self { addr })
    }

    /// The guest's address.
    pub fn addr(self) -> Ipv6Addr {
        self.addr
    }

    /// Give `eth0` the address and a default route; already-present ones are kept.
    pub fn configure(self) -> Result<(), GuestNetError> {
        let eth0: IfName = "eth0".parse().expect("eth0 is an interface name");
        let rtnl = Rtnl::open()?;
        let link = rtnl
            .link(&eth0)?
            .ok_or_else(|| GuestNetError::MissingLink(eth0.clone()))?;
        link.set_up()?;

        let addr = IpNet::V6(Ipv6Net {
            addr: self.addr,
            prefix: 128.try_into().expect("/128 is a valid IPv6 prefix"),
        });
        match link.add_addr(addr, DuplicateAddrDetection::Disabled) {
            Ok(()) | Err(AddrError::Exists(_)) => {}
            Err(e) => return Err(e.into()),
        }

        let default = Route::V6 {
            dst: Ipv6Net {
                addr: Ipv6Addr::UNSPECIFIED,
                prefix: 0.try_into().expect("/0 is a valid IPv6 prefix"),
            },
            via: Some(GATEWAY),
            dev: link.index(),
        };
        match rtnl.add_route(&default) {
            Ok(()) | Err(RouteError::Exists(_)) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::GuestNet;
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use std::net::Ipv6Addr;

    const GUEST: Ipv6Addr = Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 1, 0, 0, 5);

    #[rstest]
    #[case::among_other_params(
        "reboot=k panic=1 ip=172.16.0.2::172.16.0.1:255.255.255.252::eth0:off hyper.ip6=2001:db8::1:0:0:5",
        Some(GUEST)
    )]
    #[case::absent(
        "reboot=k panic=1 ip=172.16.0.2::172.16.0.1:255.255.255.252::eth0:off",
        None
    )]
    #[case::empty_cmdline("", None)]
    #[case::empty_value("hyper.ip6= ip=foo", None)]
    #[case::ipv4_value("hyper.ip6=10.0.0.1", None)]
    #[case::with_prefix_length("hyper.ip6=2001:db8::1:0:0:5/128", None)]
    #[case::first_wins("hyper.ip6=2001:db8::1:0:0:5 hyper.ip6=2001:db8::1:0:0:6", Some(GUEST))]
    #[case::prefix_of_another_param("xhyper.ip6=2001:db8::1:0:0:5", None)]
    fn the_guest_address_comes_from_hyper_ip6(
        #[case] cmdline: &str,
        #[case] addr: Option<Ipv6Addr>,
    ) {
        assert_eq!(GuestNet::from_cmdline(cmdline).map(GuestNet::addr), addr);
    }
}
