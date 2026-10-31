// SPDX-License-Identifier: MIT

#[cfg(feature = "stamp")]
mod stamp;

#[cfg(feature = "stamp")]
pub use stamp::{digest, section_range, stamp, stored, verify, Error};

pub const SECTION: &str = ".note.sum";
pub const LEN: usize = 32;

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
        hex(&self.get())
    }
}

pub fn hex(digest: &Digest) -> String {
    digest.iter().map(|b| format!("{b:02x}")).collect()
}

#[macro_export]
macro_rules! slot {
    ($vis:vis $name:ident) => {
        #[link_section = ".note.sum"]
        #[used]
        $vis static $name: $crate::Slot = $crate::Slot::zeroed();
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    proptest! {
        #[test]
        fn hex_round_trips_to_lowercase(digest in any::<Digest>()) {
            let rendered = hex(&digest);
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
    fn slot_macro_lands_in_the_stamped_section() {
        crate::slot!(SLOT);

        let exe = std::fs::read("/proc/self/exe").unwrap();
        let range = section_range(&exe).expect("macro must emit SECTION with LEN bytes");
        assert_eq!(stored(&exe).unwrap(), SLOT.get());
        assert_eq!(range.len(), LEN);
    }
}
