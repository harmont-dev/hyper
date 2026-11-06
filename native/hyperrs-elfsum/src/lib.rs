// SPDX-License-Identifier: MIT
//! Utility for checksumming a file. Adds a new `.note.sum` ELF section to an ELF file which
//! includes the full checksum of the ELF file itself, sans the checksum.
//!
//! This is generally useful for confirming that an ELF file was not accidentaly tampered with. It
//! does not perform any serious security guarantees as any attacker could simply tamper the
//! checksum.
//!
//! Mostly useful for ensuring that an ELF file was not corrupted, accidentally in transport, or
//! that it matches some expected version.
//!
//! # Example
//!
//! The easiest way to use this is via [`cargo-xtask`](https://github.com/matklad/cargo-xtask).
//!
//! In the binary, call [`checksum!`] to read the checksum at runtime:
//! ```no_run
//! // src/main.rs
//! # #[cfg(target_os = "linux")]
//! # fn main() {
//! let checksum: &'static hyperrs_elfsum::Slot = hyperrs_elfsum::checksum!();
//! println!("{}", checksum.hex());
//! # }
//! # #[cfg(not(target_os = "linux"))]
//! # fn main() {}
//! ```
//!
//! In a new xtask, after `cargo build`, stamp the built ELF in place (needs the `stamp` feature):
//!
//! ```no_run
//! // xtask/src/main.rs
//! # #[cfg(feature = "stamp")]
//! # fn main() -> Result<(), Box<dyn std::error::Error>> {
//! let path = "target/release/my-binary";
//! let mut bytes = std::fs::read(path)?;
//! hyperrs_elfsum::Elf::read(&mut bytes[..])?.stamp();
//! std::fs::write(path, &bytes)?;
//! # Ok(())
//! # }
//! # #[cfg(not(feature = "stamp"))]
//! # fn main() {}
//! ```
//!
//! <div class="warning">
//!
//! If you do not call [`hyperrs_elfsum::checksum!`](self::checksum) in your program, then stamping
//! will fail with [`Error::MissingSection`]. If you do not need the checksum, I recommend adding a
//!
//! ```no_run
//! // src/main.rs
//! let _checksum: &'static hyperrs_elfsum::Slot = hyperrs_elfsum::checksum!();
//! ```
//!
//! </div>
//!
//! <div class="warning">
//!
//! If you do not perform the compile-time stamping as in the `xtask`, then the resulting checksum
//! will be `0`.
//!
//! </div>

#[cfg(feature = "stamp")]
mod stamp;

#[cfg(feature = "stamp")]
pub use stamp::{Elf, Error};

const LEN: usize = 32;

pub type Digest = [u8; LEN];

#[repr(transparent)]
pub struct Slot(Digest);

impl Slot {
    #[doc(hidden)]
    pub const fn zeroed() -> Self {
        Self([0; LEN])
    }

    pub fn get(&self) -> Digest {
        unsafe { std::ptr::read_volatile(&self.0) }
    }

    pub fn hex(&self) -> String {
        self.get().iter().map(|b| format!("{b:02x}")).collect()
    }
}

#[macro_export]
macro_rules! checksum {
    () => {{
        #[link_section = ".note.sum"]
        #[used]
        static SLOT: $crate::Slot = $crate::Slot::zeroed();
        &SLOT
    }};
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn hex_round_trips_to_lowercase(digest in any::<Digest>()) {
            let rendered = Slot(digest).hex();
            prop_assert_eq!(rendered.len(), 2 * LEN);
            prop_assert!(rendered.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')));

            let decoded: Vec<u8> = (0..LEN)
                .map(|i| u8::from_str_radix(&rendered[2 * i..2 * i + 2], 16).unwrap())
                .collect();
            prop_assert_eq!(decoded.as_slice(), digest.as_slice());
        }
    }

    #[cfg(all(target_os = "linux", feature = "stamp"))]
    #[test]
    fn checksum_macro_lands_in_the_stamped_section() {
        let slot: &'static Slot = crate::checksum!();

        let exe = std::fs::read("/proc/self/exe").unwrap();
        let elf = Elf::read(exe).expect("macro must emit SECTION with LEN bytes");
        assert_eq!(*elf.stored(), slot.get());
    }
}
