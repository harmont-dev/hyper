// SPDX-License-Identifier: MIT

use super::{Action, Family, Match};
use serde::Serialize;
use std::net::Ipv4Addr;

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
    expr: Vec<Statement<'a>>,
}

/// `libnftables-json(5)`, STATEMENTS.
#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Statement<'a> {
    Match(Comparison<'a>),
    Accept(()),
    Drop(()),
    Masquerade(()),
}

impl<'a> Statement<'a> {
    fn of_match(m: &'a Match) -> Self {
        let (left, right) = match m {
            Match::Ipv4Saddr(net) => (
                Expr::Payload {
                    protocol: "ip",
                    field: "saddr",
                },
                Expr::Prefix {
                    addr: net.network(),
                    len: net.prefix.get(),
                },
            ),
            Match::Oifname(name) => (Expr::Meta { key: "oifname" }, Expr::String(name.as_str())),
        };
        Self::Match(Comparison {
            op: "==",
            left,
            right,
        })
    }

    fn of_action(action: Action) -> Self {
        match action {
            Action::Accept => Self::Accept(()),
            Action::Drop => Self::Drop(()),
            Action::Masquerade => Self::Masquerade(()),
        }
    }
}

/// `libnftables-json(5)`, MATCH.
#[derive(Serialize)]
struct Comparison<'a> {
    op: &'static str,
    left: Expr<'a>,
    right: Expr<'a>,
}

/// `libnftables-json(5)`, EXPRESSIONS.
#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Expr<'a> {
    Payload {
        protocol: &'static str,
        field: &'static str,
    },
    Meta {
        key: &'static str,
    },
    Prefix {
        addr: Ipv4Addr,
        len: u8,
    },
    #[serde(untagged)]
    String(&'a str),
}
