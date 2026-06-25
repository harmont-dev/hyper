//! Module storing the checksum of the ELF file.
//!
//! This is populated during the build process by taking the BLAKE3 sum of the
//! ELF file with the checksum zeroed out and placing it in this value. A fresh
//! (unstamped) build leaves it all-zero.
//!
//! The section name and length live in `hyper_suidhelper_meta` so the xtask that
//! stamps this section shares one source of truth. The `#[link_section]`
//! attribute below must repeat the literal — the compiler rejects a `const`
//! there — so it is the one spot that has to track `CHECKSUM_SECTION` by hand.

use hyper_suidhelper_meta::CHECKSUM_LEN;

#[link_section = ".note.sum"]
#[used]
static CHECKSUM_BLAKE3: [u8; CHECKSUM_LEN] = [0u8; CHECKSUM_LEN];

/// The raw BLAKE3 checksum of this suidhelper build.
pub fn get() -> &'static [u8; CHECKSUM_LEN] {
    &CHECKSUM_BLAKE3
}

/// The checksum rendered as a lowercase hex string.
pub fn hex() -> String {
    get().iter().map(|b| format!("{b:02x}")).collect()
}
