// SPDX-License-Identifier: MIT

use object::{Object, ObjectSection};

use crate::{Digest, LEN};

const SECTION: &str = ".note.sum";

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("not a parseable object file: {0}")]
    Parse(#[from] object::Error),
    #[error("{SECTION} section not found")]
    MissingSection,
    #[error("{SECTION} section has no file range")]
    NoFileRange,
    #[error("{SECTION} section is {0} bytes, expected {LEN}")]
    WrongSize(u64),
    #[error("{SECTION} section lies outside the file")]
    OutOfBounds,
}

pub struct Elf<B> {
    bytes: B,
    slot: usize,
}

impl<B: AsRef<[u8]>> Elf<B> {
    pub fn parse(bytes: B) -> Result<Self, Error> {
        let slot = slot_offset(bytes.as_ref())?;
        Ok(Self { bytes, slot })
    }

    fn parts(&self) -> (&[u8], &Digest, &[u8]) {
        let (before, rest) = self.bytes.as_ref().split_at(self.slot);
        let (slot, after) = rest.split_first_chunk().expect("parse validated the slot");
        (before, slot, after)
    }

    #[cfg(test)]
    pub(crate) fn stored(&self) -> &Digest {
        self.parts().1
    }

    fn digest(&self) -> Digest {
        let (before, _, after) = self.parts();
        let mut hasher = blake3::Hasher::new();
        hasher.update(before);
        hasher.update(&[0; LEN]);
        hasher.update(after);
        *hasher.finalize().as_bytes()
    }
}

impl<B: AsRef<[u8]> + AsMut<[u8]>> Elf<B> {
    pub fn stamp(&mut self) -> Digest {
        let digest = self.digest();
        let slot = self.slot;
        self.bytes.as_mut()[slot..slot + LEN].copy_from_slice(&digest);
        digest
    }
}

fn slot_offset(elf: &[u8]) -> Result<usize, Error> {
    let file = object::File::parse(elf)?;
    let section = file.section_by_name(SECTION).ok_or(Error::MissingSection)?;
    let (offset, size) = section.file_range().ok_or(Error::NoFileRange)?;
    if size != LEN as u64 {
        return Err(Error::WrongSize(size));
    }
    let offset = usize::try_from(offset).map_err(|_| Error::OutOfBounds)?;
    elf.get(offset..)
        .and_then(<[u8]>::first_chunk::<LEN>)
        .ok_or(Error::OutOfBounds)?;
    Ok(offset)
}

#[cfg(test)]
mod tests {
    use object::write::Object as Builder;
    use object::{Architecture, BinaryFormat, Endianness, SectionKind};
    use proptest::prelude::*;
    use proptest::sample::Index;

    use super::*;

    fn image(before: &[u8], slot: &[u8], after: &[u8]) -> Vec<u8> {
        let mut obj = Builder::new(BinaryFormat::Elf, Architecture::X86_64, Endianness::Little);
        for (name, data, kind) in [
            (&b".data.before"[..], before, SectionKind::Data),
            (SECTION.as_bytes(), slot, SectionKind::Note),
            (&b".data.after"[..], after, SectionKind::Data),
        ] {
            let id = obj.add_section(Vec::new(), name.to_vec(), kind);
            obj.append_section_data(id, data, 1);
        }
        obj.write().unwrap()
    }

    fn any_image() -> impl Strategy<Value = Vec<u8>> {
        (
            prop::collection::vec(any::<u8>(), 0..256),
            any::<Digest>(),
            prop::collection::vec(any::<u8>(), 0..256),
        )
            .prop_map(|(before, slot, after)| image(&before, &slot, &after))
    }

    proptest! {
        #[test]
        fn stamp_stores_the_digest_of_the_stamped_image(bytes in any_image()) {
            let mut elf = Elf::parse(bytes).unwrap();
            let digest = elf.stamp();
            prop_assert_eq!(*elf.stored(), digest);
            prop_assert_eq!(elf.digest(), digest);
        }

        #[test]
        fn stamp_is_idempotent(bytes in any_image()) {
            let mut elf = Elf::parse(bytes).unwrap();
            elf.stamp();
            let once = elf.bytes.clone();
            elf.stamp();
            prop_assert_eq!(elf.bytes, once);
        }

        #[test]
        fn digest_equals_hash_of_zeroed_image(bytes in any_image()) {
            let elf = Elf::parse(&bytes[..]).unwrap();
            let mut zeroed = bytes.clone();
            zeroed[elf.slot..elf.slot + LEN].fill(0);
            prop_assert_eq!(elf.digest(), *blake3::hash(&zeroed).as_bytes());
        }

        #[test]
        fn digest_ignores_slot_contents(
            before in prop::collection::vec(any::<u8>(), 0..256),
            after in prop::collection::vec(any::<u8>(), 0..256),
            a in any::<Digest>(),
            b in any::<Digest>(),
        ) {
            let a = Elf::parse(image(&before, &a, &after)).unwrap();
            let b = Elf::parse(image(&before, &b, &after)).unwrap();
            prop_assert_eq!(a.digest(), b.digest());
        }

        #[test]
        fn tampering_outside_the_slot_breaks_the_stamp(
            bytes in any_image(),
            at in any::<Index>(),
            flip in 1..=u8::MAX,
        ) {
            let mut elf = Elf::parse(bytes).unwrap();
            elf.stamp();
            let (slot, mut bytes) = (elf.slot, elf.bytes);
            let mut i = at.index(bytes.len() - LEN);
            if i >= slot {
                i += LEN;
            }
            bytes[i] ^= flip;
            let still_matches = Elf::parse(&bytes[..]).map(|elf| elf.digest() == *elf.stored());
            prop_assert!(!matches!(still_matches, Ok(true)));
        }

        #[test]
        fn rejects_any_slot_that_is_not_digest_sized(len in (0..128usize).prop_filter("not LEN", |&n| n != LEN)) {
            let bytes = image(b"before", &vec![0; len], b"after");
            prop_assert!(matches!(Elf::parse(bytes), Err(Error::WrongSize(n)) if n == len as u64));
        }
    }

    #[test]
    fn rejects_an_image_without_the_section() {
        let mut obj = Builder::new(BinaryFormat::Elf, Architecture::X86_64, Endianness::Little);
        let id = obj.add_section(Vec::new(), b".data".to_vec(), SectionKind::Data);
        obj.append_section_data(id, b"payload", 1);

        assert!(matches!(
            Elf::parse(obj.write().unwrap()),
            Err(Error::MissingSection)
        ));
    }

    #[test]
    fn rejects_bytes_that_are_not_an_object_file() {
        assert!(matches!(Elf::parse(b"not an elf"), Err(Error::Parse(_))));
    }
}
