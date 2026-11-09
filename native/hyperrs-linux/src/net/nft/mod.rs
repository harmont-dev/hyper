// SPDX-License-Identifier: MIT
//! nftables tables, applied through `nft`.

use super::{IfName, Ipv4Net};
use derive_more::Constructor;
use hyperrs_process::binary::RootSafeBin;
use std::io;
use std::process::Stdio;
use strum::IntoStaticStr;
use thiserror::Error as ThisError;

mod wire;

#[derive(Debug, ThisError)]
pub enum NftError {
    #[error("running nft: {0}")]
    Spawn(#[source] io::Error),
    #[error("writing the ruleset to nft: {0}")]
    Write(#[source] serde_json::Error),
    #[error("nft failed: {0}")]
    Failed(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, IntoStaticStr)]
#[strum(serialize_all = "lowercase")]
pub enum Family {
    Ip,
    Ip6,
    Inet,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, IntoStaticStr)]
#[strum(serialize_all = "lowercase")]
pub enum ChainType {
    Filter,
    Nat,
    Route,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, IntoStaticStr)]
#[strum(serialize_all = "lowercase")]
pub enum Hook {
    Prerouting,
    Input,
    Forward,
    Output,
    Postrouting,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, IntoStaticStr)]
#[strum(serialize_all = "lowercase")]
pub enum Policy {
    Accept,
    Drop,
}

/// A table and everything in it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Table {
    pub family: Family,
    pub name: String,
    pub chains: Vec<Chain>,
}

/// A base chain attached to `hook`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Chain {
    pub name: String,
    pub kind: ChainType,
    pub hook: Hook,
    pub priority: i32,
    pub policy: Policy,
    pub rules: Vec<Rule>,
}

/// Apply `action` to packets that satisfy every one of `matches`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub matches: Vec<Match>,
    pub action: Action,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Match {
    Ipv4Saddr(Ipv4Net),
    Oifname(IfName),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Accept,
    Drop,
    Masquerade,
}

/// Type-safe interface to `nft`, acting on the calling thread's network namespace.
#[derive(Debug, Constructor)]
pub struct Nft {
    bin: RootSafeBin<"nft">,
}

impl Nft {
    /// Atomically create or replace `table` so it holds exactly its chains and rules.
    pub fn replace_table(&self, table: &Table) -> Result<(), NftError> {
        self.run(&wire::Ruleset::replace(table))
    }

    /// Delete the table `name` in `family`; a missing table is `Ok`.
    pub fn delete_table(&self, family: Family, name: &str) -> Result<(), NftError> {
        self.run(&wire::Ruleset::delete(family, name))
    }

    fn run(&self, ruleset: &wire::Ruleset<'_>) -> Result<(), NftError> {
        let mut child = self
            .bin
            .command()
            .args(["-j", "-f", "-"])
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(NftError::Spawn)?;

        let stdin = child.stdin.take().expect("stdin is piped");
        let written = serde_json::to_writer(stdin, ruleset);
        let out = child.wait_with_output().map_err(NftError::Spawn)?;

        if !out.status.success() {
            return Err(NftError::Failed(
                String::from_utf8_lossy(&out.stderr).trim().to_owned(),
            ));
        }
        written.map_err(NftError::Write)
    }
}

#[cfg(test)]
mod tests {
    use super::{Action, Chain, ChainType, Family, Hook, Match, Nft, Policy, Rule, Table};
    use crate::net::netns::NetNs;
    use crate::net::{IpNet, Ipv4Net};
    use hyperrs_process::binary::RootSafeBin;
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use serde_json::{json, Value};
    use std::path::Path;
    use std::process::Command;

    const NFT: &str = "/usr/sbin/nft";
    const TABLE: &str = "test";

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

    fn nft() -> Nft {
        Nft::new(RootSafeBin::open(Path::new(NFT)).unwrap())
    }

    fn v4(net: &str) -> Ipv4Net {
        let IpNet::V4(net) = net.parse().unwrap() else {
            unreachable!("{net} is IPv4")
        };
        net
    }

    fn table(kind: ChainType, hook: Hook, rules: Vec<Rule>) -> Table {
        Table {
            family: Family::Ip,
            name: TABLE.to_owned(),
            chains: vec![Chain {
                name: "chain".to_owned(),
                kind,
                hook,
                priority: 100,
                policy: Policy::Accept,
                rules,
            }],
        }
    }

    fn prefix(addr: &str, len: u8) -> Value {
        json!({"prefix": {"addr": addr, "len": len}})
    }

    fn saddr(right: Value) -> Value {
        json!({"match": {
            "op": "==",
            "left": {"payload": {"protocol": "ip", "field": "saddr"}},
            "right": right,
        }})
    }

    fn oifname(name: &str) -> Value {
        json!({"match": {"op": "==", "left": {"meta": {"key": "oifname"}}, "right": name}})
    }

    fn listed_rules(ns: &NetNs) -> Option<Vec<Value>> {
        let out = ns
            .scoped(|| {
                Command::new(NFT)
                    .args(["-j", "list", "table", "ip", TABLE])
                    .output()
                    .unwrap()
            })
            .unwrap();
        if !out.status.success() {
            return None;
        }
        let listing: Value = serde_json::from_slice(&out.stdout).unwrap();
        Some(
            listing["nftables"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|item| item.get("rule"))
                .map(|rule| rule["expr"].clone())
                .collect(),
        )
    }

    #[rstest]
    #[case::network("nft-network", "10.200.0.0/16", "if0", prefix("10.200.0.0", 16))]
    #[case::single_address("nft-single", "172.16.0.2/32", "uplink", json!("172.16.0.2"))]
    #[case::host_bits_masked("nft-masked", "10.200.3.7/16", "if0", prefix("10.200.0.0", 16))]
    #[case::semicolon("nft-semicolon", "10.0.0.0/8", "a;flush", prefix("10.0.0.0", 8))]
    #[case::quote("nft-quote", "10.0.0.0/8", "a\"b", prefix("10.0.0.0", 8))]
    #[case::braces("nft-braces", "10.0.0.0/8", "}{", prefix("10.0.0.0", 8))]
    #[case::comment("nft-comment", "10.0.0.0/8", "#x", prefix("10.0.0.0", 8))]
    fn replacing_twice_leaves_exactly_the_given_rule_as_root(
        #[case] test: &str,
        #[case] src: &str,
        #[case] out: &str,
        #[case] listed_saddr: Value,
    ) {
        let Some(ns) = ScratchNs::new(test) else {
            return;
        };
        let table = table(
            ChainType::Nat,
            Hook::Postrouting,
            vec![Rule {
                matches: vec![
                    Match::Ipv4Saddr(v4(src)),
                    Match::Oifname(out.parse().unwrap()),
                ],
                action: Action::Masquerade,
            }],
        );
        let nft = nft();

        ns.get()
            .scoped(|| nft.replace_table(&table))
            .unwrap()
            .unwrap();
        ns.get()
            .scoped(|| nft.replace_table(&table))
            .unwrap()
            .unwrap();

        assert_eq!(
            listed_rules(ns.get()),
            Some(vec![
                json!([saddr(listed_saddr), oifname(out), {"masquerade": null}])
            ])
        );
    }

    #[rstest]
    fn replacing_drops_rules_the_new_table_no_longer_has_as_root() {
        let Some(ns) = ScratchNs::new("nft-shrink") else {
            return;
        };
        let drop_if0 = Rule {
            matches: vec![Match::Oifname("if0".parse().unwrap())],
            action: Action::Drop,
        };
        let accept_lan = Rule {
            matches: vec![Match::Ipv4Saddr(v4("10.0.0.0/8"))],
            action: Action::Accept,
        };
        let nft = nft();

        let both = table(
            ChainType::Filter,
            Hook::Forward,
            vec![drop_if0, accept_lan.clone()],
        );
        ns.get()
            .scoped(|| nft.replace_table(&both))
            .unwrap()
            .unwrap();
        let one = table(ChainType::Filter, Hook::Forward, vec![accept_lan]);
        ns.get()
            .scoped(|| nft.replace_table(&one))
            .unwrap()
            .unwrap();

        assert_eq!(
            listed_rules(ns.get()),
            Some(vec![
                json!([saddr(prefix("10.0.0.0", 8)), {"accept": null}])
            ])
        );
    }

    #[rstest]
    fn deleting_a_table_is_idempotent_as_root() {
        let Some(ns) = ScratchNs::new("nft-delete") else {
            return;
        };
        let nft = nft();
        let table = table(ChainType::Nat, Hook::Postrouting, vec![]);

        ns.get()
            .scoped(|| nft.replace_table(&table))
            .unwrap()
            .unwrap();
        ns.get()
            .scoped(|| nft.delete_table(Family::Ip, TABLE))
            .unwrap()
            .unwrap();
        ns.get()
            .scoped(|| nft.delete_table(Family::Ip, TABLE))
            .unwrap()
            .unwrap();

        assert_eq!(listed_rules(ns.get()), None);
    }
}
