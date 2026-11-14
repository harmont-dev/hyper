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
    #[case::at_the_cap(Rules::MAX, true)]
    #[case::past_the_cap(Rules::MAX + 1, false)]
    fn a_direction_takes_exactly_max_rules(#[case] len: usize, #[case] accepted: bool) {
        let rules = vec![json!({"protocol": "tcp", "ports": [22, 22]}); len];
        assert_eq!(
            serde_json::from_value::<Rules>(json!(rules)).is_ok(),
            accepted
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

#[cfg(test)]
mod refusal_properties {
    //! Laws over arbitrary policies as the helper's JSON delivers them:
    //! - a policy is accepted exactly when every rule names `tcp` or `udp` over a
    //!   non-empty range without port 0 and each direction holds at most `Rules::MAX`;
    //! - an accepted policy renders one destination-port match per rule, in order, over
    //!   exactly the ports it named.

    use super::{Firewall, Rules};
    use hyperrs_linux::net::nft::{L4Proto, Match};
    use proptest::prelude::*;
    use serde_json::{json, Value};
    use test_strategy::proptest;

    #[derive(Debug, Clone)]
    struct Raw {
        protocol: &'static str,
        first: u16,
        last: u16,
    }

    impl Raw {
        fn valid(&self) -> bool {
            matches!(self.protocol, "tcp" | "udp") && self.first != 0 && self.first <= self.last
        }

        fn json(&self) -> Value {
            json!({"protocol": self.protocol, "ports": [self.first, self.last]})
        }

        fn rendered(&self) -> Match {
            let proto = if self.protocol == "tcp" {
                L4Proto::Tcp
            } else {
                L4Proto::Udp
            };
            Match::Dport(proto, self.first..=self.last)
        }
    }

    fn port() -> impl Strategy<Value = u16> {
        prop_oneof![Just(0), Just(1), Just(u16::MAX), any::<u16>()]
    }

    fn raw() -> impl Strategy<Value = Raw> {
        (
            prop_oneof![
                8 => Just("tcp"),
                8 => Just("udp"),
                1 => Just("icmp"),
                1 => Just("TCP"),
                1 => Just(""),
            ],
            port(),
            port(),
        )
            .prop_map(|(protocol, first, last)| Raw {
                protocol,
                first,
                last,
            })
    }

    fn direction() -> impl Strategy<Value = Vec<Raw>> {
        prop_oneof![
            4 => prop::collection::vec(raw(), 0..8),
            1 => (Rules::MAX - 2..=Rules::MAX + 2).prop_flat_map(|len| {
                prop::collection::vec(
                    (1u16..=u16::MAX).prop_map(|p| Raw {
                        protocol: "tcp",
                        first: p,
                        last: p,
                    }),
                    len,
                )
            }),
        ]
    }

    #[proptest]
    fn a_policy_is_accepted_exactly_when_every_rule_and_direction_is_valid(
        #[strategy(direction())] inbound: Vec<Raw>,
        #[strategy(direction())] outbound_blocked: Vec<Raw>,
    ) {
        let ok = |rules: &[Raw]| rules.len() <= Rules::MAX && rules.iter().all(Raw::valid);
        let parsed = serde_json::from_value::<Firewall>(json!({
            "inbound": inbound.iter().map(Raw::json).collect::<Vec<_>>(),
            "outbound_blocked": outbound_blocked.iter().map(Raw::json).collect::<Vec<_>>(),
        }));

        prop_assert_eq!(parsed.is_ok(), ok(&inbound) && ok(&outbound_blocked));
        if let Ok(firewall) = parsed {
            prop_assert_eq!(
                firewall.inbound().collect::<Vec<_>>(),
                inbound.iter().map(Raw::rendered).collect::<Vec<_>>()
            );
            prop_assert_eq!(
                firewall.outbound_blocked().collect::<Vec<_>>(),
                outbound_blocked
                    .iter()
                    .map(Raw::rendered)
                    .collect::<Vec<_>>()
            );
        }
    }

    #[proptest]
    fn ports_outside_u16_are_refused(
        #[strategy(prop_oneof![-70_000i64..0, 65_536i64..200_000])] bad: i64,
        first: bool,
    ) {
        let ports = if first {
            json!([bad, 80])
        } else {
            json!([80, bad])
        };
        let policy = json!({
            "inbound": [{"protocol": "tcp", "ports": ports}],
            "outbound_blocked": [],
        });

        prop_assert!(serde_json::from_value::<Firewall>(policy).is_err());
    }
}
