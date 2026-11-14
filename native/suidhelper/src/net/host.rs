// SPDX-License-Identifier: MIT
//! Host-wide networking, applied by `host_init`.

use super::{Blocked, Filter, Masquerade, NetId, NodePrefix, TABLE};
use hyperrs_linux::net::link::LinkError;
use hyperrs_linux::net::nft::{
    Action, Chain, CtState, Family, Hook, Icmpv6Type, Iface, Match, Nft, NftError, Policy, Rule,
    Table,
};
use hyperrs_linux::net::{IfName, IpNet, Rtnl, RtnlOpenError};
use hyperrs_linux::sysctl::{AcceptRa, Sysctl, SysctlError};
use hyperrs_process::privilege::Root;
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
    #[error(transparent)]
    Rtnl(#[from] RtnlOpenError),
    #[error(transparent)]
    Link(#[from] LinkError),
    #[error("uplink {0} is not an interface on this host; set [net] uplink to the one on the default route")]
    NoUplink(IfName),
    #[error(
        "{0} is off; VMs need the host to forward: set {0}=1 (and persist it in /etc/sysctl.d)"
    )]
    ForwardingOff(&'static str),
}

/// The host side of VM networking, routed out of `uplink`.
pub struct HostNet<'a> {
    pub uplink: &'a IfName,
    pub prefix: NodePrefix,
    pub blocked: &'a Blocked,
}

impl HostNet<'_> {
    /// Forward and proxy NDP for VMs, masquerade their IPv4 out of `uplink`, and
    /// firewall them off from the host, its network, and inbound connections.
    pub fn init(&self, root: &Root<'_>, nft: &Nft) -> Result<(), HostNetError> {
        if Rtnl::open()?.link(self.uplink)?.is_none() {
            return Err(HostNetError::NoUplink(self.uplink.clone()));
        }
        if !Sysctl::net().ipv4().current_ip_forward()? {
            return Err(HostNetError::ForwardingOff("net.ipv4.ip_forward"));
        }
        if !Sysctl::net().ipv6().conf_all().current_forwarding()? {
            return Err(HostNetError::ForwardingOff("net.ipv6.conf.all.forwarding"));
        }
        let uplink_conf = || Sysctl::net().ipv6().conf(self.uplink);
        if uplink_conf().current_accept_ra()? == AcceptRa::UnlessForwarding {
            uplink_conf()
                .accept_ra(AcceptRa::EvenWhenForwarding)
                .write()?;
        }
        Sysctl::net()
            .ipv6()
            .conf(self.uplink)
            .proxy_ndp(true)
            .write()?;

        nft.replace_table(root, &self.table())?;
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
                self.forward(),
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
    fn forward(&self) -> Chain {
        let vm_range = Match::Ipv6Daddr(self.prefix.vm_range());
        let not_vm_range = || Match::Not(Box::new(vm_range.clone()));
        Filter {
            hook: Hook::Forward,
            policy: Policy::Accept,
            rules: [
                Match::CtState(CtState::Invalid),
                Match::Not(Box::new(Match::Ipv4Saddr(NetId::transit_range()))),
                Match::Not(Box::new(Match::Ipv6Saddr(self.prefix.vm_range()))),
            ]
            .into_iter()
            .map(|matches| Self::from_vms(matches, Action::Drop))
            .chain(self.blocked.ranges().map(|range| {
                let daddr = match range {
                    IpNet::V4(net) => Match::Ipv4Daddr(net),
                    IpNet::V6(net) => Match::Ipv6Daddr(net),
                };
                Self::from_vms(daddr, Action::Drop)
            }))
            .chain([Rule {
                matches: vec![
                    Match::Iifname(VM_VETHS.clone()),
                    Match::Ipv6Daddr(self.prefix.get()),
                    not_vm_range(),
                    Match::CtState(CtState::New),
                ],
                action: Action::Drop,
            }])
            .chain([CtState::Invalid, CtState::New].map(|state| Rule {
                matches: vec![
                    Match::Ipv4Daddr(NetId::transit_range()),
                    Match::CtState(state),
                ],
                action: Action::Drop,
            }))
            .chain([Rule {
                matches: vec![Match::Oifname(VM_VETHS.clone()), not_vm_range()],
                action: Action::Drop,
            }])
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
