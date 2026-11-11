// SPDX-License-Identifier: MIT

use super::{Action, Family, Iface, Match};
use serde::Serialize;
use std::net::IpAddr;

/// `libnftables-json(5)`, RULESET.
#[derive(Serialize)]
pub struct Ruleset<'a> {
    nftables: Vec<Command<'a>>,
}

impl<'a> Ruleset<'a> {
    pub fn replace(table: &'a super::Table) -> Self {
        let chains = table.chains.iter().flat_map(|chain| {
            let rules = chain.rules.iter().map(|rule| {
                Command::Add(Object::Rule(Rule {
                    family: table.family.into(),
                    table: &table.name,
                    chain: &chain.name,
                    expr: rule
                        .matches
                        .iter()
                        .map(Statement::of_match)
                        .chain([Statement::of_action(rule.action)])
                        .collect(),
                }))
            });
            [Command::Add(Object::Chain(Chain {
                family: table.family.into(),
                table: &table.name,
                name: &chain.name,
                kind: chain.kind.into(),
                hook: chain.hook.into(),
                prio: chain.priority,
                policy: chain.policy.into(),
            }))]
            .into_iter()
            .chain(rules)
        });

        Self {
            nftables: Self::delete(table.family, &table.name)
                .nftables
                .into_iter()
                .chain([Command::Add(Object::Table(Table::of(
                    table.family,
                    &table.name,
                )))])
                .chain(chains)
                .collect(),
        }
    }

    pub fn delete(family: Family, name: &'a str) -> Self {
        Self {
            nftables: vec![
                Command::Add(Object::Table(Table::of(family, name))),
                Command::Delete(Object::Table(Table::of(family, name))),
            ],
        }
    }
}

/// `libnftables-json(5)`, COMMAND OBJECTS.
#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Command<'a> {
    Add(Object<'a>),
    Delete(Object<'a>),
}

/// `libnftables-json(5)`, RULESET ELEMENTS.
#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Object<'a> {
    Table(Table<'a>),
    Chain(Chain<'a>),
    Rule(Rule<'a>),
}

/// `libnftables-json(5)`, TABLE.
#[derive(Serialize)]
struct Table<'a> {
    family: &'static str,
    name: &'a str,
}

impl<'a> Table<'a> {
    fn of(family: Family, name: &'a str) -> Self {
        Self {
            family: family.into(),
            name,
        }
    }
}

/// `libnftables-json(5)`, CHAIN.
#[derive(Serialize)]
struct Chain<'a> {
    family: &'static str,
    table: &'a str,
    name: &'a str,
    #[serde(rename = "type")]
    kind: &'static str,
    hook: &'static str,
    prio: i32,
    policy: &'static str,
}

/// `libnftables-json(5)`, RULE.
#[derive(Serialize)]
struct Rule<'a> {
    family: &'static str,
    table: &'a str,
    chain: &'a str,
    expr: Vec<Statement>,
}

/// `libnftables-json(5)`, STATEMENTS.
#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Statement {
    Match(Comparison),
    Accept(()),
    Drop(()),
    Masquerade(()),
    Dnat(Dnat),
}

/// `libnftables-json(5)`, DNAT.
#[derive(Serialize)]
struct Dnat {
    family: &'static str,
    addr: IpAddr,
}

impl Statement {
    fn of_match(m: &Match) -> Self {
        let (op, left, right) = match m {
            Match::Ipv4Saddr(net) => ("==", Expr::payload("ip", "saddr"), Expr::v4(*net)),
            Match::Ipv4Daddr(net) => ("==", Expr::payload("ip", "daddr"), Expr::v4(*net)),
            Match::Ipv6Saddr(net) => ("==", Expr::payload("ip6", "saddr"), Expr::v6(*net)),
            Match::Ipv6Daddr(net) => ("==", Expr::payload("ip6", "daddr"), Expr::v6(*net)),
            Match::Iifname(iface) => ("==", Expr::Meta { key: "iifname" }, Expr::iface(iface)),
            Match::Oifname(iface) => ("==", Expr::Meta { key: "oifname" }, Expr::iface(iface)),
            Match::CtState(state) => (
                "in",
                Expr::Ct { key: "state" },
                Expr::Static((*state).into()),
            ),
            Match::Icmpv6Type(kind) => (
                "==",
                Expr::payload("icmpv6", "type"),
                Expr::Static((*kind).into()),
            ),
            Match::Skuid(uid) => (
                "==",
                Expr::Meta { key: "skuid" },
                Expr::Number(uid.as_raw()),
            ),
            Match::Dport(proto, ports) => (
                "==",
                Expr::payload((*proto).into(), "dport"),
                Expr::ports(ports),
            ),
            Match::Not(inner) => {
                let Self::Match(comparison) = Self::of_match(inner) else {
                    unreachable!("a match renders as a comparison")
                };
                return Self::Match(Comparison {
                    op: "!=",
                    ..comparison
                });
            }
        };
        Self::Match(Comparison { op, left, right })
    }

    fn of_action(action: Action) -> Self {
        match action {
            Action::Accept => Self::Accept(()),
            Action::Drop => Self::Drop(()),
            Action::Masquerade => Self::Masquerade(()),
            Action::Dnat(addr) => Self::Dnat(Dnat {
                family: Family::Ip.into(),
                addr: IpAddr::V4(addr),
            }),
        }
    }
}

/// `libnftables-json(5)`, MATCH.
#[derive(Serialize)]
struct Comparison {
    op: &'static str,
    left: Expr,
    right: Expr,
}

/// `libnftables-json(5)`, EXPRESSIONS.
#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Expr {
    Payload {
        protocol: &'static str,
        field: &'static str,
    },
    Meta {
        key: &'static str,
    },
    Ct {
        key: &'static str,
    },
    Prefix {
        addr: IpAddr,
        len: u8,
    },
    Range([u16; 2]),
    #[serde(untagged)]
    Static(&'static str),
    #[serde(untagged)]
    String(String),
    #[serde(untagged)]
    Number(u32),
}

impl Expr {
    fn payload(protocol: &'static str, field: &'static str) -> Self {
        Self::Payload { protocol, field }
    }

    fn v4(net: super::Ipv4Net) -> Self {
        Self::Prefix {
            addr: IpAddr::V4(net.network()),
            len: net.prefix.get(),
        }
    }

    fn v6(net: super::Ipv6Net) -> Self {
        Self::Prefix {
            addr: IpAddr::V6(net.network()),
            len: net.prefix.get(),
        }
    }

    /// A single port is a plain number, which is how nft lists one back.
    fn ports(ports: &std::ops::RangeInclusive<u16>) -> Self {
        let (first, last) = (*ports.start(), *ports.end());
        if first == last {
            return Self::Number(u32::from(first));
        }
        Self::Range([first, last])
    }

    /// nft reads a trailing `*` as a wildcard, so an exact name escapes its own.
    fn iface(iface: &Iface) -> Self {
        Self::String(match iface {
            Iface::Named(name) => match name.as_str().strip_suffix('*') {
                Some(stem) => format!("{stem}\\*"),
                None => name.as_str().to_owned(),
            },
            Iface::Prefixed(stem) => format!("{stem}*"),
        })
    }
}
