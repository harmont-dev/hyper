// SPDX-License-Identifier: MIT
//! The jailer's caller-supplied argument newtypes. Each parses via `FromStr`, so
//! clap refuses a bad value at argument-parse time.
//!
//! ## Laws (property-tested in `tests/tools/jailer.rs`)
//! - [`CgroupSetting`] re-renders a valid pair to its canonical `key=value` and
//!   rejects unknown keys and values outside the per-key grammar.
//! - [`JailSock`] accepts exactly `/` + one filename and rejects multi-component,
//!   relative, `..`, and NUL/whitespace inputs.

use super::Error;
use std::fmt;
use std::str::FromStr;

/// The jailer protects at most a handful of controllers; an unbounded `--cgroup`
/// list is a caller trying something. Cap it well above any legitimate need.
pub const MAX_CGROUPS: usize = 16;

/// `sun_path` in `sockaddr_un` is 108 bytes on Linux; a socket path longer than
/// that can never be bound, so reject it up front.
const MAX_SOCK_LEN: usize = 108;

/// `1..=20` ASCII digits — bounds a numeric cgroup limit without pulling in a
/// regex engine. The upper bound comfortably exceeds `u64::MAX`'s 20 digits.
fn is_digits_1_20(s: &str) -> bool {
    !s.is_empty() && s.len() <= 20 && s.bytes().all(|b| b.is_ascii_digit())
}

/// A single `KEY=VALUE` cgroup setting from an allowlist. The helper re-emits
/// `key=value` itself from the canonical key, so the jailer never sees the
/// caller's raw bytes. Per-key value grammar:
///   - `memory.max` : `[0-9]{1,20}` or the literal `max`
///   - `cpu.max`    : `[0-9]{1,20} [0-9]{1,20}` or `max [0-9]{1,20}`
#[derive(Debug, Clone)]
pub struct CgroupSetting {
    key: &'static str,
    value: String,
}

impl FromStr for CgroupSetting {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let reject = || Error::Cgroup(s.to_string());
        // Split on the FIRST `=`. None of the value grammars contains a `=`, so a
        // second `=` lands in `value` and is rejected by the grammar check below.
        let (raw_key, value) = s.split_once('=').ok_or_else(reject)?;

        let key: &'static str = match raw_key {
            "memory.max" => "memory.max",
            "cpu.max" => "cpu.max",
            _ => return Err(reject()),
        };

        let valid = match key {
            "memory.max" => value == "max" || is_digits_1_20(value),
            "cpu.max" => match value.split_once(' ') {
                Some((quota, period)) => {
                    (quota == "max" || is_digits_1_20(quota)) && is_digits_1_20(period)
                }
                None => false,
            },
            _ => false,
        };

        if valid {
            Ok(Self {
                key,
                value: value.to_string(),
            })
        } else {
            Err(reject())
        }
    }
}

impl fmt::Display for CgroupSetting {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}={}", self.key, self.value)
    }
}

/// The firecracker API socket path: an absolute path that is exactly `/` plus one
/// filename in `[A-Za-z0-9_.-]`. The charset excludes `/`, so the value is always
/// a direct child of `/` with no extra components and no traversal; `.`/`..` as
/// the whole filename are rejected explicitly.
#[derive(Debug, Clone)]
pub struct JailSock(String);

impl FromStr for JailSock {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let reject = || Error::Sock(s.to_string());
        if s.len() > MAX_SOCK_LEN {
            return Err(reject());
        }
        let name = s.strip_prefix('/').ok_or_else(reject)?;
        if name.is_empty() || name == "." || name == ".." {
            return Err(reject());
        }
        if !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-')
        {
            return Err(reject());
        }
        Ok(Self(s.to_string()))
    }
}

impl fmt::Display for JailSock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
