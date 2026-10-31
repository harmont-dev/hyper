// SPDX-License-Identifier: MIT

use std::ops::Range;

use object::{Object, ObjectSection};

use crate::{Digest, LEN, SECTION};

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

pub fn section_range(elf: &[u8]) -> Result<Range<usize>, Error> {
    let file = object::File::parse(elf)?;
    let section = file.section_by_name(SECTION).ok_or(Error::MissingSection)?;
    let (offset, size) = section.file_range().ok_or(Error::NoFileRange)?;
    if size != LEN as u64 {
        return Err(Error::WrongSize(size));
    }
    let start = usize::try_from(offset).map_err(|_| Error::OutOfBounds)?;
    let end = start
        .checked_add(LEN)
        .filter(|&end| end <= elf.len())
        .ok_or(Error::OutOfBounds)?;
    Ok(start..end)
}

pub fn digest(elf: &[u8]) -> Result<Digest, Error> {
    let slot = section_range(elf)?;
    Ok(digest_around(elf, &slot))
}

pub fn stored(elf: &[u8]) -> Result<Digest, Error> {
    let slot = section_range(elf)?;
    Ok(read_slot(elf, slot))
}

pub fn stamp(elf: &mut [u8]) -> Result<Digest, Error> {
    let slot = section_range(elf)?;
    let digest = digest_around(elf, &slot);
    elf[slot].copy_from_slice(&digest);
    Ok(digest)
}

pub fn verify(elf: &[u8]) -> Result<bool, Error> {
    let slot = section_range(elf)?;
    Ok(digest_around(elf, &slot) == read_slot(elf, slot))
}

fn digest_around(elf: &[u8], slot: &Range<usize>) -> Digest {
    let mut hasher = blake3::Hasher::new();
    hasher.update(&elf[..slot.start]);
    hasher.update(&[0; LEN]);
    hasher.update(&elf[slot.end..]);
    *hasher.finalize().as_bytes()
}

fn read_slot(elf: &[u8], slot: Range<usize>) -> Digest {
    let mut digest = [0; LEN];
    digest.copy_from_slice(&elf[slot]);
    digest
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
        fn stamped_image_verifies(mut elf in any_image()) {
            let digest = stamp(&mut elf).unwrap();
            prop_assert_eq!(stored(&elf).unwrap(), digest);
            prop_assert!(verify(&elf).unwrap());
        }

        #[test]
        fn stamp_is_idempotent(mut elf in any_image()) {
            stamp(&mut elf).unwrap();
            let once = elf.clone();
            stamp(&mut elf).unwrap();
            prop_assert_eq!(elf, once);
        }

        #[test]
        fn digest_equals_hash_of_zeroed_image(elf in any_image()) {
            let mut zeroed = elf.clone();
            let slot = section_range(&elf).unwrap();
            zeroed[slot].fill(0);
            prop_assert_eq!(digest(&elf).unwrap(), *blake3::hash(&zeroed).as_bytes());
        }

        #[test]
        fn digest_ignores_slot_contents(
            before in prop::collection::vec(any::<u8>(), 0..256),
            after in prop::collection::vec(any::<u8>(), 0..256),
            a in any::<Digest>(),
            b in any::<Digest>(),
        ) {
            prop_assert_eq!(
                digest(&image(&before, &a, &after)).unwrap(),
                digest(&image(&before, &b, &after)).unwrap()
            );
        }

        #[test]
        fn tampering_outside_the_slot_never_verifies(
            mut elf in any_image(),
            at in any::<Index>(),
            flip in 1..=u8::MAX,
        ) {
            stamp(&mut elf).unwrap();
            let slot = section_range(&elf).unwrap();
            let mut i = at.index(elf.len() - LEN);
            if i >= slot.start {
                i += LEN;
            }
            elf[i] ^= flip;
            prop_assert!(!matches!(verify(&elf), Ok(true)));
        }

        #[test]
        fn rejects_any_slot_that_is_not_digest_sized(len in (0..128usize).prop_filter("not LEN", |&n| n != LEN)) {
            let elf = image(b"before", &vec![0; len], b"after");
            prop_assert!(matches!(digest(&elf), Err(Error::WrongSize(n)) if n == len as u64));
        }
    }

    #[test]
    fn rejects_an_image_without_the_section() {
        let mut obj = Builder::new(BinaryFormat::Elf, Architecture::X86_64, Endianness::Little);
        let id = obj.add_section(Vec::new(), b".data".to_vec(), SectionKind::Data);
        obj.append_section_data(id, b"payload", 1);
        let elf = obj.write().unwrap();

        assert!(matches!(digest(&elf), Err(Error::MissingSection)));
    }

    #[test]
    fn rejects_bytes_that_are_not_an_object_file() {
        assert!(matches!(verify(b"not an elf"), Err(Error::Parse(_))));
    }
}
