// SPDX-License-Identifier: MIT
//! Networking utilities.

pub mod link;
pub mod netns;
pub mod route;
mod rtnl;

pub use rtnl::{RequestError, Rtnl, RtnlOpenError};

use derive_more::{AsRef, Display};
use hyperrs_fs::path::StrictComponent;
use std::net::{AddrParseError, IpAddr, Ipv4Addr, Ipv6Addr};
use std::num::{NonZeroU32, ParseIntError};
use std::str::FromStr;
use thiserror::Error as ThisError;

const IFNAMSIZ: usize = 16;

#[derive(Debug, ThisError, PartialEq, Eq)]
pub enum IfNameError {
    #[error("invalid character in interface name")]
    InvalidCharacter,
    #[error("interface name is too long")]
    TooLong,
    #[error("interface name is empty")]
    Empty,
}

/// Name of a linux interface.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Display, AsRef)]
#[as_ref(str)]
pub struct IfName(String);

impl IfName {
    /// The name as a string.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The name as a path component, e.g. for `/proc/sys/net/ipv6/conf/<name>`.
    pub fn as_component(&self) -> &StrictComponent {
        self.0
            .as_str()
            .try_into()
            .expect("an interface name is a strict path component")
    }
}

impl FromStr for IfName {
    type Err = IfNameError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "" => return Err(IfNameError::Empty),
            "." | ".." => return Err(IfNameError::InvalidCharacter),
            _ => {}
        }
        if s.len() >= IFNAMSIZ {
            return Err(IfNameError::TooLong);
        }
        if s.chars().any(|c| {
            matches!(
                c,
                '/' | ':' | '\0' | ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r'
            )
        }) {
            return Err(IfNameError::InvalidCharacter);
        }
        Ok(Self(s.to_owned()))
    }
}

#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("interface index 0 is never assigned by the kernel")]
pub struct ZeroIfIndex;

/// Index of an interface within its network namespace, as rtnetlink reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Display)]
pub struct IfIndex(NonZeroU32);

impl IfIndex {
    /// The raw index.
    pub fn get(self) -> u32 {
        self.0.get()
    }
}

impl TryFrom<u32> for IfIndex {
    type Error = ZeroIfIndex;

    fn try_from(index: u32) -> Result<Self, Self::Error> {
        NonZeroU32::new(index).map(Self).ok_or(ZeroIfIndex)
    }
}

#[derive(Debug, ThisError, PartialEq, Eq)]
#[error("prefix length {len} is past /{max}")]
pub struct PrefixError {
    len: u8,
    max: u8,
}

/// The CIDR notation prefix. In `0.200.0.1/30`, this is `30`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Display)]
pub struct Prefix<const MAX: u8>(u8);

impl<const MAX: u8> Prefix<MAX> {
    /// The prefix length in bits.
    pub fn get(self) -> u8 {
        self.0
    }
}

impl<const MAX: u8> TryFrom<u8> for Prefix<MAX> {
    type Error = PrefixError;

    fn try_from(len: u8) -> Result<Self, Self::Error> {
        if len > MAX {
            return Err(PrefixError { len, max: MAX });
        }
        Ok(Self(len))
    }
}

/// An IPV4 network address, encoding both the address and the prefix length.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Display)]
#[display("{addr}/{prefix}")]
pub struct Ipv4Net {
    pub addr: Ipv4Addr,
    pub prefix: Prefix<32>,
}

/// An IPV6 network address, encoding both the address and the prefix length.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Display)]
#[display("{addr}/{prefix}")]
pub struct Ipv6Net {
    pub addr: Ipv6Addr,
    pub prefix: Prefix<128>,
}

/// Either an ipv4 or an ipv6 address
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Display)]
pub enum IpNet {
    V4(Ipv4Net),
    V6(Ipv6Net),
}

impl IpNet {
    /// The address, without the prefix length.
    pub fn addr(self) -> IpAddr {
        match self {
            Self::V4(net) => IpAddr::V4(net.addr),
            Self::V6(net) => IpAddr::V6(net.addr),
        }
    }

    /// The prefix length in bits.
    pub fn prefix_len(self) -> u8 {
        match self {
            Self::V4(net) => net.prefix.get(),
            Self::V6(net) => net.prefix.get(),
        }
    }
}

#[derive(Debug, ThisError)]
pub enum IpNetParseError {
    #[error("{0:?} has no `/<prefix length>`")]
    NoPrefix(String),
    #[error("{0:?}: {1}")]
    Addr(String, #[source] AddrParseError),
    #[error("{0:?}: prefix length is not a decimal number")]
    PrefixNotDecimal(String),
    #[error("{0:?}: {1}")]
    PrefixRange(String, #[source] ParseIntError),
    #[error("{0:?}: {1}")]
    Prefix(String, #[source] PrefixError),
}

impl FromStr for IpNet {
    type Err = IpNetParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let Some((addr, len)) = s.split_once('/') else {
            return Err(IpNetParseError::NoPrefix(s.to_owned()));
        };

        let addr: IpAddr = addr
            .parse()
            .map_err(|e| IpNetParseError::Addr(s.to_owned(), e))?;

        if len.is_empty() || !len.bytes().all(|b| b.is_ascii_digit()) {
            return Err(IpNetParseError::PrefixNotDecimal(s.to_owned()));
        }

        let len: u8 = len
            .parse()
            .map_err(|e| IpNetParseError::PrefixRange(s.to_owned(), e))?;

        let prefix_err = |e| IpNetParseError::Prefix(s.to_owned(), e);
        Ok(match addr {
            IpAddr::V4(addr) => Self::V4(Ipv4Net {
                addr,
                prefix: len.try_into().map_err(prefix_err)?,
            }),
            IpAddr::V6(addr) => Self::V6(Ipv6Net {
                addr,
                prefix: len.try_into().map_err(prefix_err)?,
            }),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{IfIndex, IfName, IfNameError, IpNet, Prefix};
    use pretty_assertions::assert_eq;
    use proptest::prelude::*;
    use rstest::rstest;
    use test_strategy::proptest;

    #[proptest]
    fn interface_names_round_trip(#[strategy("[a-zA-Z0-9_.-]{1,15}")] name: String) {
        prop_assume!(name != "." && name != "..");
        let parsed: IfName = name.parse().unwrap();
        prop_assert_eq!(parsed.to_string(), name);
    }

    #[proptest]
    fn interface_names_past_15_bytes_are_refused(#[strategy("[a-z]{16,64}")] name: String) {
        prop_assert_eq!(name.parse::<IfName>(), Err(IfNameError::TooLong));
    }

    #[proptest]
    fn interface_names_with_a_forbidden_byte_are_refused(
        #[strategy("[a-z]{0,7}")] head: String,
        #[strategy(prop::sample::select(vec!['/', ':', '\0', ' ', '\t', '\n', '\x0b', '\x0c', '\r']))]
        bad: char,
        #[strategy("[a-z]{0,6}")] tail: String,
    ) {
        let name = format!("{head}{bad}{tail}");
        prop_assert_eq!(name.parse::<IfName>(), Err(IfNameError::InvalidCharacter));
    }

    #[proptest]
    fn every_interface_name_is_a_strict_component(#[strategy("[^/:\\s\\x00]{1,15}")] name: String) {
        if let Ok(parsed) = name.parse::<IfName>() {
            prop_assert_eq!(parsed.as_component().as_os_str(), name.as_str());
        }
    }

    #[rstest]
    #[case::empty("", IfNameError::Empty)]
    #[case::current_dir(".", IfNameError::InvalidCharacter)]
    #[case::parent_dir("..", IfNameError::InvalidCharacter)]
    fn degenerate_interface_names_are_refused(#[case] name: &str, #[case] expected: IfNameError) {
        assert_eq!(name.parse::<IfName>(), Err(expected));
    }

    #[rstest]
    #[case::zero(0, false)]
    #[case::one(1, true)]
    #[case::max(u32::MAX, true)]
    fn interface_index_zero_is_refused(#[case] index: u32, #[case] accepted: bool) {
        assert_eq!(IfIndex::try_from(index).is_ok(), accepted);
    }

    #[proptest]
    fn prefixes_up_to_max_are_accepted(len: u8) {
        prop_assert_eq!(Prefix::<32>::try_from(len).is_ok(), len <= 32);
        prop_assert_eq!(Prefix::<128>::try_from(len).is_ok(), len <= 128);
    }

    #[proptest]
    fn ipv4_nets_round_trip(addr: std::net::Ipv4Addr, #[strategy(0u8..=32)] len: u8) {
        let s = format!("{addr}/{len}");
        let net: IpNet = s.parse().unwrap();
        prop_assert_eq!(net.to_string(), s);
        prop_assert_eq!(net.addr(), std::net::IpAddr::V4(addr));
        prop_assert_eq!(net.prefix_len(), len);
    }

    #[proptest]
    fn ipv6_nets_round_trip(addr: std::net::Ipv6Addr, #[strategy(0u8..=128)] len: u8) {
        let s = format!("{addr}/{len}");
        let net: IpNet = s.parse().unwrap();
        prop_assert_eq!(net.to_string(), s);
        prop_assert_eq!(net.addr(), std::net::IpAddr::V6(addr));
        prop_assert_eq!(net.prefix_len(), len);
    }

    #[rstest]
    #[case::no_prefix("10.0.0.1")]
    #[case::empty_prefix("10.0.0.1/")]
    #[case::v4_past_32("10.0.0.1/33")]
    #[case::v6_past_128("fe80::1/129")]
    #[case::past_u8("fe80::1/256")]
    #[case::signed_prefix("10.0.0.1/+8")]
    #[case::negative_prefix("10.0.0.1/-1")]
    #[case::two_prefixes("10.0.0.1/8/8")]
    #[case::not_an_address("eth0/8")]
    #[case::scoped_v6("fe80::1%eth0/64")]
    fn malformed_nets_are_refused(#[case] s: &str) {
        assert!(s.parse::<IpNet>().is_err(), "accepted {s:?}");
    }
}
