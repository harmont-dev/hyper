// SPDX-License-Identifier: MIT
//! A VM's port policy: the inbound ports open to it and the outbound ports it may not use.
//!
//! Laws the tests hold this to:
//! - a port range is never empty and never names port 0;
//! - a direction holds at most [`Rules::MAX`] rules, so a request cannot hand `nft` an
//!   unbounded ruleset.

use hyperrs_linux::net::nft::{L4Proto, Match};
use serde::Deserialize;
use std::num::NonZeroU16;
use thiserror::Error as ThisError;

#[derive(Debug, ThisError, PartialEq, Eq)]
pub enum FirewallError {
    #[error("port 0 is not a port")]
    PortZero,
    #[error("port range {first}-{last} is empty")]
    EmptyRange { first: u16, last: u16 },
    #[error("{0} rules is more than the {max} a direction holds", max = Rules::MAX)]
    TooManyRules(usize),
}

/// What reaches a VM, and what it may not reach.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Firewall {
    inbound: Rules,
    outbound_blocked: Rules,
}

impl Firewall {
    /// One destination-port match per inbound rule.
    pub fn inbound(&self) -> impl Iterator<Item = Match> + '_ {
        self.inbound.matches()
    }

    /// One destination-port match per blocked outbound rule.
    pub fn outbound_blocked(&self) -> impl Iterator<Item = Match> + '_ {
        self.outbound_blocked.matches()
    }
}

/// One direction's rules.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(try_from = "Vec<PortRule>")]
pub struct Rules(Vec<PortRule>);

impl Rules {
    pub const MAX: usize = 128;

    fn matches(&self) -> impl Iterator<Item = Match> + '_ {
        self.0.iter().map(|rule| {
            Match::Dport(
                rule.protocol.into(),
                rule.ports.first.get()..=rule.ports.last.get(),
            )
        })
    }
}

impl TryFrom<Vec<PortRule>> for Rules {
    type Error = FirewallError;

    fn try_from(rules: Vec<PortRule>) -> Result<Self, Self::Error> {
        if rules.len() > Self::MAX {
            return Err(FirewallError::TooManyRules(rules.len()));
        }
        Ok(Self(rules))
    }
}

/// `protocol` traffic to a destination port in `ports`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortRule {
    protocol: Protocol,
    ports: PortRange,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Tcp,
    Udp,
}

impl From<Protocol> for L4Proto {
    fn from(protocol: Protocol) -> Self {
        match protocol {
            Protocol::Tcp => Self::Tcp,
            Protocol::Udp => Self::Udp,
        }
    }
}

/// An inclusive, non-empty port range, written `[first, last]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(try_from = "[u16; 2]")]
pub struct PortRange {
    first: NonZeroU16,
    last: NonZeroU16,
}

impl TryFrom<[u16; 2]> for PortRange {
    type Error = FirewallError;

    fn try_from([first, last]: [u16; 2]) -> Result<Self, Self::Error> {
        if first > last {
            return Err(FirewallError::EmptyRange { first, last });
        }
        Ok(Self {
            first: NonZeroU16::new(first).ok_or(FirewallError::PortZero)?,
            last: NonZeroU16::new(last).ok_or(FirewallError::PortZero)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{Firewall, PortRange, Rules};
    use hyperrs_linux::net::nft::{L4Proto, Match};
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use serde_json::json;
    use test_strategy::proptest;

    #[proptest]
    fn a_port_range_is_accepted_exactly_when_it_is_non_empty_and_avoids_zero(
        first: u16,
        last: u16,
    ) {
        prop_assert_eq!(
            PortRange::try_from([first, last]).is_ok(),
            first != 0 && first <= last
        );
    }

    #[proptest]
    fn a_direction_takes_at_most_max_rules(#[strategy(0usize..=2 * Rules::MAX)] len: usize) {
        let rules = vec![json!({"protocol": "tcp", "ports": [22, 22]}); len];
        prop_assert_eq!(
            serde_json::from_value::<Rules>(json!(rules)).is_ok(),
            len <= Rules::MAX
        );
    }

    #[rstest]
    fn rules_become_destination_port_matches_in_order() {
        let firewall: Firewall = serde_json::from_value(json!({
            "inbound": [
                {"protocol": "tcp", "ports": [22, 22]},
                {"protocol": "udp", "ports": [6000, 6010]},
            ],
            "outbound_blocked": [{"protocol": "tcp", "ports": [25, 25]}],
        }))
        .unwrap();

        assert_eq!(
            (
                firewall.inbound().collect::<Vec<_>>(),
                firewall.outbound_blocked().collect::<Vec<_>>(),
            ),
            (
                vec![
                    Match::Dport(L4Proto::Tcp, 22..=22),
                    Match::Dport(L4Proto::Udp, 6000..=6010),
                ],
                vec![Match::Dport(L4Proto::Tcp, 25..=25)],
            )
        );
    }

    #[rstest]
    #[case::icmp(json!({"inbound": [{"protocol": "icmp", "ports": [1, 1]}], "outbound_blocked": []}))]
    #[case::one_port(json!({"inbound": [{"protocol": "tcp", "ports": [22]}], "outbound_blocked": []}))]
    #[case::unknown_rule_field(json!({"inbound": [{"protocol": "tcp", "ports": [22, 22], "action": "drop"}],
        "outbound_blocked": []}))]
    #[case::missing_direction(json!({"inbound": []}))]
    #[case::unknown_direction(json!({"inbound": [], "outbound_blocked": [], "outbound": []}))]
    fn malformed_policies_are_refused(#[case] policy: serde_json::Value) {
        assert!(serde_json::from_value::<Firewall>(policy).is_err());
    }
}
