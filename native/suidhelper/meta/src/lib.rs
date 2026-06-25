//! Constants shared between the suidhelper binary, which declares the checksum
//! section, and xtask, which stamps it. Kept in a tiny stable leaf crate so
//! neither side has to depend on the other (the binary is a nightly crate).
//!
//! Note: `#[link_section = ...]` requires a string literal, so the binary still
//! repeats the section name in that attribute — [`CHECKSUM_SECTION`] is the
//! shared source of truth for every *non-attribute* use (the xtask lookup, the
//! array length, docs).

/// ELF section carrying the binary's BLAKE3 self-checksum.
pub const CHECKSUM_SECTION: &str = ".note.sum";

/// BLAKE3 digest length, in bytes.
pub const CHECKSUM_LEN: usize = 32;
