// SPDX-License-Identifier: MIT
//! Contract of the strict path types every confinement check in the helper is built on.
//!
//! Laws under test, each against an independent byte-level oracle:
//! - **Component oracle.** A byte string is a [`StrictComponent`] iff it is non-empty, not `.`/`..`,
//!   at most `NAME_MAX` bytes, and holds no `/`, NUL or ASCII whitespace. Non-UTF-8 bytes are fine.
//! - **Path oracle.** A raw byte path is a strict absolute [`SafePathBuf`] iff it starts with `/`
//!   and either is exactly `/` or every `/`-separated segment passes the component oracle. Parsing
//!   through `&str`, `PathBuf` and `&Path` all agree.
//! - **Already normal.** An accepted path is a fixed point of std's component normalization, so no
//!   later `Path::components`/`join` can reinterpret it.
//! - **`strip_base` is component-prefix.** It returns exactly the trailing segments when the base's
//!   segments are a proper prefix, `EqualsBase` on equality, `NotUnderBase` otherwise (including a
//!   byte-prefix that is not a component prefix, e.g. `/ab` under `/a`).
//! - **`split_last` inverts `join`.** For any non-root path, `parent.join(name)` rebuilds it, the
//!   parent is itself strict, and `name` is `file_name()`; `/` has no split.

use hyperrs_fs::path::{
    ComponentError, IsAbsolute, RelativeError, SafePath, SafePathBuf, StrictComponent,
    StrictComponents, ValidationError, NAME_MAX,
};
use proptest::prelude::*;
use std::assert_matches;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};

type Strict = SafePathBuf<IsAbsolute, StrictComponents>;

fn oracle_component(bytes: &[u8]) -> bool {
    !bytes.is_empty()
        && bytes != b"."
        && bytes != b".."
        && bytes.len() <= NAME_MAX
        && !bytes
            .iter()
            .any(|b| matches!(b, b'/' | 0 | b' ' | b'\t' | b'\n' | 0x0b | 0x0c | b'\r'))
}

fn oracle_path(raw: &[u8]) -> bool {
    match raw {
        [b'/'] => true,
        [b'/', rest @ ..] => rest.split(|&b| b == b'/').all(oracle_component),
        _ => false,
    }
}

fn byte() -> impl Strategy<Value = u8> {
    prop_oneof![
        6 => b'a'..=b'z',
        2 => Just(b'.'),
        1 => Just(b'/'),
        1 => Just(0u8),
        1 => prop::sample::select(vec![b' ', b'\t', b'\n', 0x0b, 0x0c, b'\r']),
        1 => 0x80u8..=0xff,
        1 => Just(b'-'),
    ]
}

fn component_bytes() -> impl Strategy<Value = Vec<u8>> {
    prop_oneof![
        8 => prop::collection::vec(byte(), 0..6),
        1 => prop::collection::vec(b'a'..=b'z', NAME_MAX - 2..NAME_MAX + 3),
        1 => prop::sample::select(vec![b".".to_vec(), b"..".to_vec(), b"...".to_vec(), b".a".to_vec()]),
    ]
}

fn raw_path() -> impl Strategy<Value = Vec<u8>> {
    (
        any::<bool>(),
        prop::collection::vec(component_bytes(), 0..5),
        any::<bool>(),
    )
        .prop_map(|(absolute, segments, trailing)| {
            let mut raw = if absolute { b"/".to_vec() } else { Vec::new() };
            raw.extend(segments.join(&b'/'));
            if trailing {
                raw.push(b'/');
            }
            raw
        })
}

fn strict_raw(raw: &[u8]) -> Result<Strict, ValidationError> {
    PathBuf::from(OsStr::from_bytes(raw)).try_into()
}

fn seg() -> impl Strategy<Value = &'static str> {
    prop::sample::select(vec!["a", "b", "ab", "a.b", "-"])
}

fn abs(segments: &[&str]) -> Strict {
    format!("/{}", segments.join("/")).parse().unwrap()
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(2048))]

    #[test]
    fn component_accepts_exactly_the_oracle(bytes in component_bytes()) {
        let got = <&StrictComponent>::try_from(OsStr::from_bytes(&bytes));
        prop_assert_eq!(got.is_ok(), oracle_component(&bytes), "{:?}", bytes);
        if let Ok(name) = got {
            prop_assert_eq!(name.as_os_str().as_bytes(), &bytes[..]);
            let owned = name.to_owned();
            prop_assert_eq!(owned.as_os_str().as_bytes(), &bytes[..]);
        }
    }

    #[test]
    fn path_accepts_exactly_the_oracle(raw in raw_path()) {
        let got = strict_raw(&raw);
        prop_assert_eq!(got.is_ok(), oracle_path(&raw), "{:?}", String::from_utf8_lossy(&raw));
        if raw.first() != Some(&b'/') {
            prop_assert!(matches!(got, Err(ValidationError::NotAbsolute)));
        }
        let borrowed: Result<&SafePath<IsAbsolute, StrictComponents>, _> =
            Path::new(OsStr::from_bytes(&raw)).try_into();
        prop_assert_eq!(borrowed.is_ok(), got.is_ok());
        if let Ok(utf8) = std::str::from_utf8(&raw) {
            prop_assert_eq!(utf8.parse::<Strict>().is_ok(), got.is_ok());
        }
    }

    #[test]
    fn accepted_paths_are_already_normal(raw in raw_path()) {
        if let Ok(path) = strict_raw(&raw) {
            let normal: PathBuf = path.as_path().components().collect();
            prop_assert_eq!(normal.as_os_str().as_bytes(), &raw[..]);
            prop_assert!(path
                .as_path()
                .components()
                .all(|c| matches!(c, Component::RootDir | Component::Normal(_))));
        }
    }

    #[test]
    fn strip_base_is_a_component_prefix(
        base in prop::collection::vec(seg(), 0..3),
        path in prop::collection::vec(seg(), 0..5),
    ) {
        let got = abs(&path).strip_base(&abs(&base)).map(|rel| {
            rel.segments()
                .map(|s| s.as_os_str().to_string_lossy().into_owned())
                .collect::<Vec<_>>()
        });
        if base == path {
            prop_assert!(matches!(got, Err(RelativeError::EqualsBase)), "{got:?}");
        } else if path.starts_with(&base) {
            let want: Vec<String> = path[base.len()..].iter().map(|s| s.to_string()).collect();
            prop_assert_eq!(got.unwrap(), want);
        } else {
            prop_assert!(matches!(got, Err(RelativeError::NotUnderBase)), "{got:?}");
        }
    }

    #[test]
    fn split_last_inverts_join(path in prop::collection::vec(seg(), 0..5)) {
        let full = abs(&path);
        match full.split_last() {
            None => prop_assert!(path.is_empty()),
            Some((parent, name)) => {
                let rebuilt = parent.join(name);
                let want_parent = abs(&path[..path.len() - 1]);
                prop_assert_eq!(rebuilt.as_path(), full.as_path());
                prop_assert_eq!(parent.as_path(), want_parent.as_path());
                prop_assert!(strict_raw(parent.as_path().as_os_str().as_bytes()).is_ok());
                prop_assert_eq!(Some(name), full.file_name());
                prop_assert_eq!(name.as_os_str(), OsStr::new(path[path.len() - 1]));
            }
        }
    }

    #[test]
    fn split_last_inverts_join_on_relative_paths(
        base in prop::collection::vec(seg(), 0..3),
        rest in prop::collection::vec(seg(), 2..5),
    ) {
        let full_segments: Vec<&str> = base.iter().chain(rest.iter()).copied().collect();
        let full = abs(&full_segments);
        let base = abs(&base);
        let rel = full.strip_base(&base).unwrap();
        let (parent, name) = rel.split_last().unwrap();
        let rebuilt = parent.join(name);
        prop_assert_eq!(rebuilt.as_path(), rel.as_path());
        prop_assert_eq!(rel.file_name(), Some(name));
    }
}

#[test]
fn name_max_is_the_exact_component_length_boundary() {
    let at = "a".repeat(NAME_MAX);
    let over = "a".repeat(NAME_MAX + 1);
    assert!(<&StrictComponent>::try_from(at.as_str()).is_ok());
    assert_matches!(
        <&StrictComponent>::try_from(over.as_str()),
        Err(ComponentError::TooLong(n)) if n == NAME_MAX + 1
    );
    assert!(format!("/{at}/{at}").parse::<Strict>().is_ok());
    assert_matches!(
        format!("/{at}/{over}").parse::<Strict>(),
        Err(ValidationError::Component(ComponentError::TooLong(_)))
    );
}

#[test]
fn byte_prefix_that_is_not_a_component_prefix_is_not_under_base() {
    assert_matches!(
        abs(&["ab", "c"]).strip_base(&abs(&["a"])),
        Err(RelativeError::NotUnderBase)
    );
}
