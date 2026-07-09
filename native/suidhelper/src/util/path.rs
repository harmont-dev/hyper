// SPDX-License-Identifier: AGPL-3.0-only
//! Fallible conversion of paths and strings to NUL-terminated C strings, for
//! handing to `execve`-family syscalls.
//!
//! The natural spelling — `impl TryFrom<&Path> for CString` — is forbidden by
//! the orphan rule (both types belong to `std`), hence an extension trait.

use std::ffi::{CString, NulError};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;

/// Convert to a [`CString`]; fails iff the value contains an interior NUL byte.
pub trait ToCStringExt {
    fn to_cstring(&self) -> Result<CString, NulError>;
}

impl ToCStringExt for Path {
    fn to_cstring(&self) -> Result<CString, NulError> {
        CString::new(self.as_os_str().as_bytes())
    }
}

impl ToCStringExt for str {
    fn to_cstring(&self) -> Result<CString, NulError> {
        CString::new(self.as_bytes())
    }
}
