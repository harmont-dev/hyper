// SPDX-License-Identifier: MIT
//! Host-wide networking, applied by `host_init`.

use super::{Filter, Masquerade, NetId, NON_PUBLIC, TABLE};
use hyperrs_linux::net::nft::{
    Action, Chain, CtState, Family, Hook, Icmpv6Type, Iface, Match, Nft, NftError, Policy, Rule,
    Table,
};
use hyperrs_linux::net::{IfName, IpNet};
use hyperrs_linux::sysctl::{Sysctl, SysctlError};
use std::sync::LazyLock;
use thiserror::Error as ThisError;

static VM_VETHS: LazyLock<Iface> =
    LazyLock::new(|| Iface::Prefixed("vm-veth-".parse().expect("vm-veth- is an interface name")));

#[derive(Debug, ThisError)]
pub enum HostNetError {
    #[error(transparent)]
    Sysctl(#[from] SysctlError),
    #[error("host firewall: {0}")]
    Nft(#[from] NftError),
}

/// The host side of VM networking, routed out of `uplink`.
pub struct HostNet<'a> {
    pub uplink: &'a IfName,
}

impl HostNet<'_> {
    /// Forward and proxy NDP for VMs, masquerade their IPv4 out of `uplink`, and
    /// firewall them off from the host, its network, and inbound connections.
    pub fn init(&self, nft: &Nft) -> Result<(), HostNetError> {
        Sysctl::net().ipv4().ip_forward(true).write()?;
        Sysctl::net().ipv6().conf_all().forwarding(true).write()?;
        Sysctl::net()
            .ipv6()
            .conf(self.uplink)
            .proxy_ndp(true)
            .write()?;

        nft.replace_table(&self.table())?;
        Ok(())
    }

    fn table(&self) -> Table {
        Table {
            family: Family::Inet,
            name: TABLE.to_owned(),
            chains: vec![
                Masquerade {
                    src: NetId::transit_range(),
                    out: self.uplink,
                }
                .chain(),
                Self::input(),
                Self::forward(),
            ],
        }
    }

    /// VMs reach the host only to answer what it started, and for neighbour discovery
    /// on their veth.
    fn input() -> Chain {
        Filter {
            hook: Hook::Input,
            policy: Policy::Accept,
            rules: [
                Match::CtState(CtState::Established),
                Match::CtState(CtState::Related),
                Match::Icmpv6Type(Icmpv6Type::NeighborSolicit),
                Match::Icmpv6Type(Icmpv6Type::NeighborAdvert),
            ]
            .into_iter()
            .map(|allowed| Self::from_vms(allowed, Action::Accept))
            .chain([Rule {
                matches: vec![Match::Iifname(VM_VETHS.clone())],
                action: Action::Drop,
            }])
            .collect(),
        }
        .chain()
    }

    /// VMs reach only public addresses. What reaches a VM is its own namespace's
    /// firewall to decide.
    fn forward() -> Chain {
        Filter {
            hook: Hook::Forward,
            policy: Policy::Accept,
            rules: NON_PUBLIC
                .iter()
                .map(|range| {
                    let daddr = match range.parse().expect("the non-public ranges parse") {
                        IpNet::V4(net) => Match::Ipv4Daddr(net),
                        IpNet::V6(net) => Match::Ipv6Daddr(net),
                    };
                    Self::from_vms(daddr, Action::Drop)
                })
                .collect(),
        }
        .chain()
    }

    fn from_vms(matches: Match, action: Action) -> Rule {
        Rule {
            matches: vec![Match::Iifname(VM_VETHS.clone()), matches],
            action,
        }
    }
}
