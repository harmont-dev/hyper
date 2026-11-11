// SPDX-License-Identifier: MIT
//! nftables tables, applied through `nft`.

use super::{IfName, Ipv4Net, Ipv6Net};
use derive_more::Constructor;
use hyperrs_process::binary::RootSafeBin;
use nix::unistd::Uid;
use std::io;
use std::net::Ipv4Addr;
use std::ops::RangeInclusive;
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
    Ipv4Daddr(Ipv4Net),
    Ipv6Saddr(Ipv6Net),
    Ipv6Daddr(Ipv6Net),
    Iifname(Iface),
    Oifname(Iface),
    CtState(CtState),
    Icmpv6Type(Icmpv6Type),
    Skuid(Uid),
    Dport(L4Proto, RangeInclusive<u16>),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, IntoStaticStr)]
#[strum(serialize_all = "lowercase")]
pub enum L4Proto {
    Tcp,
    Udp,
}

/// The interfaces a name match covers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Iface {
    /// Exactly this interface.
    Named(IfName),
    /// Every interface whose name starts with this.
    Prefixed(IfName),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, IntoStaticStr)]
#[strum(serialize_all = "lowercase")]
pub enum CtState {
    New,
    Established,
    Related,
    Invalid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, IntoStaticStr)]
pub enum Icmpv6Type {
    #[strum(serialize = "nd-neighbor-solicit")]
    NeighborSolicit,
    #[strum(serialize = "nd-neighbor-advert")]
    NeighborAdvert,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Accept,
    Drop,
    Masquerade,
    Dnat(Ipv4Addr),
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
    use super::{
        Action, Chain, ChainType, CtState, Family, Hook, Icmpv6Type, Iface, L4Proto, Match, Nft,
        Policy, Rule, Table,
    };
    use crate::net::netns::NetNs;
    use crate::net::{IpNet, Ipv4Net, Ipv6Net};
    use hyperrs_process::binary::RootSafeBin;
    use nix::unistd::Uid;
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

    fn v6(net: &str) -> Ipv6Net {
        let IpNet::V6(net) = net.parse().unwrap() else {
            unreachable!("{net} is IPv6")
        };
        net
    }

    fn named(name: &str) -> Iface {
        Iface::Named(name.parse().unwrap())
    }

    fn table(kind: ChainType, hook: Hook, rules: Vec<Rule>) -> Table {
        Table {
            family: Family::Inet,
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
                    .args(["-j", "list", "table", "inet", TABLE])
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
                matches: vec![Match::Ipv4Saddr(v4(src)), Match::Oifname(named(out))],
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
    #[case::ipv4_daddr(Match::Ipv4Daddr(v4("169.254.0.0/16")), json!({"match": {"op": "==",
        "left": {"payload": {"protocol": "ip", "field": "daddr"}},
        "right": prefix("169.254.0.0", 16)}}))]
    #[case::ipv6_saddr(Match::Ipv6Saddr(v6("2001:db8::1:0:0:5/128")), json!({"match": {"op": "==",
        "left": {"payload": {"protocol": "ip6", "field": "saddr"}},
        "right": "2001:db8::1:0:0:5"}}))]
    #[case::ipv6_daddr(Match::Ipv6Daddr(v6("fc00::/7")), json!({"match": {"op": "==",
        "left": {"payload": {"protocol": "ip6", "field": "daddr"}},
        "right": prefix("fc00::", 7)}}))]
    #[case::iifname_exact(Match::Iifname(named("tap0")), json!({"match": {"op": "==",
        "left": {"meta": {"key": "iifname"}}, "right": "tap0"}}))]
    #[case::iifname_prefix(Match::Iifname(Iface::Prefixed("vm-veth-".parse().unwrap())),
        json!({"match": {"op": "==", "left": {"meta": {"key": "iifname"}}, "right": "vm-veth-*"}}))]
    #[case::oifname_literal_star(Match::Oifname(named("a*")), json!({"match": {"op": "==",
        "left": {"meta": {"key": "oifname"}}, "right": "a\\*"}}))]
    #[case::ct_state(Match::CtState(CtState::Established), json!({"match": {"op": "in",
        "left": {"ct": {"key": "state"}}, "right": "established"}}))]
    #[case::icmpv6_type(Match::Icmpv6Type(Icmpv6Type::NeighborSolicit), json!({"match": {
        "op": "==", "left": {"payload": {"protocol": "icmpv6", "field": "type"}},
        "right": "nd-neighbor-solicit"}}))]
    #[case::skuid(Match::Skuid(Uid::from_raw(900_001)), json!({"match": {"op": "==",
        "left": {"meta": {"key": "skuid"}}, "right": 900_001}}))]
    #[case::single_port(Match::Dport(L4Proto::Tcp, 25..=25), json!({"match": {"op": "==",
        "left": {"payload": {"protocol": "tcp", "field": "dport"}}, "right": 25}}))]
    #[case::port_range(Match::Dport(L4Proto::Udp, 6000..=6010), json!({"match": {"op": "==",
        "left": {"payload": {"protocol": "udp", "field": "dport"}}, "right": {"range": [6000, 6010]}}}))]
    fn every_match_lists_back_as_given_as_root(#[case] matches: Match, #[case] listed: Value) {
        let Some(ns) = ScratchNs::new("nft-match") else {
            return;
        };
        let table = table(
            ChainType::Filter,
            Hook::Forward,
            vec![Rule {
                matches: vec![matches],
                action: Action::Drop,
            }],
        );
        let nft = nft();

        ns.get()
            .scoped(|| nft.replace_table(&table))
            .unwrap()
            .unwrap();

        assert_eq!(
            listed_rules(ns.get()),
            Some(vec![json!([listed, {"drop": null}])])
        );
    }

    #[rstest]
    fn a_dnat_lists_back_as_given_as_root() {
        let Some(ns) = ScratchNs::new("nft-dnat") else {
            return;
        };
        let table = table(
            ChainType::Nat,
            Hook::Prerouting,
            vec![Rule {
                matches: vec![Match::Dport(L4Proto::Udp, 53..=53)],
                action: Action::Dnat("192.0.2.53".parse().unwrap()),
            }],
        );
        let nft = nft();

        ns.get()
            .scoped(|| nft.replace_table(&table))
            .unwrap()
            .unwrap();

        assert_eq!(
            listed_rules(ns.get()),
            Some(vec![json!([
                {"match": {"op": "==",
                    "left": {"payload": {"protocol": "udp", "field": "dport"}}, "right": 53}},
                {"dnat": {"family": "ip", "addr": "192.0.2.53"}},
            ])])
        );
    }

    #[rstest]
    fn replacing_drops_rules_the_new_table_no_longer_has_as_root() {
        let Some(ns) = ScratchNs::new("nft-shrink") else {
            return;
        };
        let drop_if0 = Rule {
            matches: vec![Match::Oifname(named("if0"))],
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
            .scoped(|| nft.delete_table(Family::Inet, TABLE))
            .unwrap()
            .unwrap();
        ns.get()
            .scoped(|| nft.delete_table(Family::Inet, TABLE))
            .unwrap()
            .unwrap();

        assert_eq!(listed_rules(ns.get()), None);
    }
}
