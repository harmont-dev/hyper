// SPDX-License-Identifier: MIT

use object::{Object, ObjectSection};

use crate::{Digest, LEN};

const SECTION: &str = ".note.sum";

#[derive(Debug, thiserror::Error)]
pub enum StampError {
    #[error("not a parseable object file: {0}")]
    Parse(#[from] object::Error),
    #[error("{SECTION} section not found")]
    MissingSection,
    #[error("{SECTION} section has no file range")]
    NoFileRange,
    #[error("{SECTION} section is {0} bytes, expected {LEN}")]
    WrongSize(u64),
}

pub struct Elf<B> {
    bytes: B,
    slot: usize,
}

impl<B: AsRef<[u8]>> Elf<B> {
    pub fn read(bytes: B) -> Result<Self, StampError> {
        let slot = slot_offset(bytes.as_ref())?;
        Ok(Self { bytes, slot })
    }

    fn parts(&self) -> (&[u8], &[u8]) {
        let (before, rest) = self.bytes.as_ref().split_at(self.slot);
        let (_, after) = rest
            .split_first_chunk::<LEN>()
            .expect("read validated the slot");
        (before, after)
    }

    fn digest(&self) -> Digest {
        let (before, after) = self.parts();
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

fn slot_offset(elf: &[u8]) -> Result<usize, StampError> {
    let file = object::File::parse(elf)?;
    let section = file
        .section_by_name(SECTION)
        .ok_or(StampError::MissingSection)?;
    <&Digest>::try_from(section.data()?).map_err(|_| StampError::WrongSize(section.size()))?;
    let (offset, _) = section.file_range().ok_or(StampError::NoFileRange)?;
    Ok(usize::try_from(offset).expect("data() bounds-checked the section against the file"))
}

#[cfg(test)]
mod tests {
    use object::write::Object as Builder;
    use object::{Architecture, BinaryFormat, Endianness, SectionKind};
    use proptest::prelude::*;
    use proptest::sample::Index;
    use rstest::rstest;
    use std::assert_matches;
    use test_strategy::proptest;

    use super::*;

    fn image(before: &[u8], slot: &[u8], after: &[u8]) -> Vec<u8> {
        let mut obj = Builder::new(BinaryFormat::Elf, Architecture::X86_64, Endianness::Little);
        for (name, data, kind) in [
            (&b".data.before"[..], before, SectionKind::Data),
            (&b".note.sum"[..], slot, SectionKind::Note),
            (&b".data.after"[..], after, SectionKind::Data),
        ] {
            let id = obj.add_section(Vec::new(), name.to_vec(), kind);
            obj.append_section_data(id, data, 1);
        }
        obj.write().unwrap()
    }

    fn stamped(mut bytes: Vec<u8>) -> (Vec<u8>, Digest) {
        let digest = Elf::read(&mut bytes[..]).unwrap().stamp();
        (bytes, digest)
    }

    fn position(bytes: &[u8], needle: &[u8]) -> usize {
        bytes
            .windows(needle.len())
            .position(|window| window == needle)
            .unwrap()
    }

    fn any_bytes() -> impl Strategy<Value = Vec<u8>> {
        prop::collection::vec(any::<u8>(), 0..256)
    }

    fn any_image() -> impl Strategy<Value = Vec<u8>> {
        (any_bytes(), any::<Digest>(), any_bytes())
            .prop_map(|(before, slot, after)| image(&before, &slot, &after))
    }

    #[proptest]
    fn stamp_writes_only_its_digest_into_the_slot(
        #[strategy(any_bytes())] before: Vec<u8>,
        slot: Digest,
        #[strategy(any_bytes())] after: Vec<u8>,
    ) {
        let bytes = image(&before, &slot, &after);
        let at = position(&bytes, &slot);
        let (stamped, digest) = stamped(bytes.clone());

        let mut expected = bytes;
        expected[at..at + LEN].copy_from_slice(&digest);
        prop_assert_eq!(stamped, expected);
    }

    #[proptest]
    fn stamp_is_idempotent(#[strategy(any_image())] bytes: Vec<u8>) {
        let (once, digest) = stamped(bytes);
        let (twice, again) = stamped(once.clone());
        prop_assert_eq!(twice, once);
        prop_assert_eq!(again, digest);
    }

    #[proptest]
    fn digest_equals_hash_of_zeroed_image(
        #[strategy(any_bytes())] before: Vec<u8>,
        slot: Digest,
        #[strategy(any_bytes())] after: Vec<u8>,
    ) {
        let bytes = image(&before, &slot, &after);
        let mut zeroed = bytes.clone();
        let at = position(&bytes, &slot);
        zeroed[at..at + LEN].fill(0);
        prop_assert_eq!(stamped(bytes).1, *blake3::hash(&zeroed).as_bytes());
    }

    #[proptest]
    fn digest_ignores_slot_contents(
        #[strategy(any_bytes())] before: Vec<u8>,
        #[strategy(any_bytes())] after: Vec<u8>,
        a: Digest,
        b: Digest,
    ) {
        let a = stamped(image(&before, &a, &after)).1;
        let b = stamped(image(&before, &b, &after)).1;
        prop_assert_eq!(a, b);
    }

    #[proptest]
    fn tampering_outside_the_slot_breaks_the_stamp(
        #[strategy(any_image())] bytes: Vec<u8>,
        at: Index,
        #[strategy(1..=u8::MAX)] flip: u8,
    ) {
        let (mut bytes, digest) = stamped(bytes);
        let slot = position(&bytes, &digest);
        let i = at.index(bytes.len() - LEN);
        bytes[if i >= slot { i + LEN } else { i }] ^= flip;
        let restamped = Elf::read(&mut bytes[..]).map(|mut elf| elf.stamp());
        prop_assert!(!matches!(restamped, Ok(d) if d == digest));
    }

    #[proptest]
    fn rejects_any_slot_that_is_not_digest_sized(
        #[strategy((0..128usize).prop_filter("not LEN", |&n| n != LEN))] len: usize,
    ) {
        let bytes = image(b"before", &vec![0; len], b"after");
        assert_matches!(Elf::read(bytes).err(), Some(StampError::WrongSize(n)) if n == len as u64);
    }

    #[rstest]
    fn rejects_an_image_without_the_section() {
        let mut obj = Builder::new(BinaryFormat::Elf, Architecture::X86_64, Endianness::Little);
        let id = obj.add_section(Vec::new(), b".data".to_vec(), SectionKind::Data);
        obj.append_section_data(id, b"payload", 1);

        assert_matches!(
            Elf::read(obj.write().unwrap()).err(),
            Some(StampError::MissingSection)
        );
    }

    #[rstest]
    fn rejects_bytes_that_are_not_an_object_file() {
        assert_matches!(Elf::read(b"not an elf").err(), Some(StampError::Parse(_)));
    }
}
