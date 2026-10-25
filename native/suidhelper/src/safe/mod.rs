// SPDX-License-Identifier: MIT
//! Validated-by-construction types. Each wraps a value whose only constructor
//! runs the safety checks, so holding one is proof the checks passed — the
//! privileged code downstream never re-validates, it just demands the type.
//!
//! - [`fs`] — confined, fd-relative filesystem access.
//! - [`bin`] — a root-owned tool binary we are allowed to run.
//! - [`dev`] — a device-node operand that names one of Hyper's own devices.

pub mod bin;
pub mod dev;
pub mod fs;
