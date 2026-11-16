//! What the kernel parses out of a rendered table, not what Rust's tokenizer
//! sees. `dmsetup` reads the `<start> <length> <target>` header with C-locale
//! `isspace` and libdm backslash-escapes the params, then the kernel's
//! `dm_split_args` splits them with the kernel's `isspace`, which (lib/ctype.c)
//! also treats byte 0xA0 as a space. Laws:
//!   * for every table the types let us construct, the argv the kernel builds
//!     is exactly the operands the struct names, byte for byte: a path operand
//!     is opened as itself, never as a prefix of itself plus an extra token;
//!   * the same holds for every thin-pool message;
//!   * tables built only from dm names and loop devices (all the helper ever
//!     hands the kernel) are faithful for the whole dm-name charset.

use hyperrs_linux::dm::{
    DevPath, DmName, DmTable, LinearTable, Origin, Persistence, SnapshotTable, ThinId, ThinMessage,
    ThinPoolTable, ThinTable,
};
use hyperrs_linux::loopdev::LoopDevNum;
use proptest::prelude::*;
use rstest::rstest;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use test_strategy::proptest;

fn kernel_is_space(b: u8) -> bool {
    matches!(b, b'\t' | b'\n' | 0x0b | 0x0c | b'\r' | b' ' | 0xa0)
}

fn kernel_argv(rendered: &str) -> Vec<String> {
    rendered
        .as_bytes()
        .split(|&b| kernel_is_space(b))
        .filter(|t| !t.is_empty())
        .map(|t| t.escape_ascii().to_string())
        .collect()
}

fn escaped(words: Vec<Vec<u8>>) -> Vec<String> {
    words
        .into_iter()
        .map(|w| w.escape_ascii().to_string())
        .collect()
}

fn origin_bytes(o: &Origin) -> Vec<u8> {
    match o {
        Origin::Device(n) => n.path().as_path().as_os_str().as_bytes().to_vec(),
        Origin::Path(p) => path_bytes(p),
    }
}

fn path_bytes(p: &DevPath) -> Vec<u8> {
    p.as_path().as_os_str().as_bytes().to_vec()
}

fn num(n: impl ToString) -> Vec<u8> {
    n.to_string().into_bytes()
}

fn operands(t: &DmTable) -> Vec<Vec<u8>> {
    let mut v = vec![b"0".to_vec()];
    match t {
        DmTable::Linear(l) => {
            v.extend([num(l.sectors), b"linear".to_vec(), origin_bytes(&l.origin)]);
            v.push(b"0".to_vec());
        }
        DmTable::Snapshot(s) => v.extend([
            num(s.sectors),
            b"snapshot".to_vec(),
            origin_bytes(&s.origin),
            path_bytes(&s.cow),
            num(s.persistence),
            num(s.chunk),
        ]),
        DmTable::ThinPool(p) => v.extend([
            num(p.sectors),
            b"thin-pool".to_vec(),
            path_bytes(&p.metadata),
            path_bytes(&p.data),
            num(p.block_sectors),
            num(p.low_water),
        ]),
        DmTable::Thin(t) => {
            v.extend([
                num(t.sectors),
                b"thin".to_vec(),
                t.pool.path().as_path().as_os_str().as_bytes().to_vec(),
                num(t.id),
            ]);
            v.extend(t.origin.as_ref().map(origin_bytes));
        }
    }
    v
}

fn component_char() -> impl Strategy<Value = char> {
    any::<char>().prop_filter("strict component", |c| {
        !matches!(c, '/' | '\0' | ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r')
    })
}

fn component() -> impl Strategy<Value = String> {
    prop::collection::vec(component_char(), 1..6)
        .prop_map(|cs| cs.into_iter().collect::<String>())
        .prop_filter("not . or ..", |s| s != "." && s != "..")
}

fn dev_path() -> impl Strategy<Value = DevPath> {
    prop::collection::vec(component(), 1..4).prop_filter_map("not a DevPath", |parts| {
        PathBuf::from(format!("/{}", parts.join("/")))
            .try_into()
            .ok()
    })
}

fn dm_name() -> impl Strategy<Value = DmName> {
    "[0-9A-Za-z#+.:=@_][0-9A-Za-z#+.:=@_-]{0,40}".prop_filter_map("reserved", |s| s.parse().ok())
}

fn thin_id() -> impl Strategy<Value = ThinId> {
    (0..=ThinId::MAX).prop_map(|n| ThinId::new(n).unwrap())
}

fn persistence() -> impl Strategy<Value = Persistence> {
    prop_oneof![Just(Persistence::Persistent), Just(Persistence::Transient)]
}

fn table(path: BoxedStrategy<DevPath>) -> impl Strategy<Value = DmTable> {
    let origin = prop_oneof![
        dm_name().prop_map(Origin::Device),
        path.clone().prop_map(Origin::Path)
    ];
    prop_oneof![
        (any::<u64>(), origin.clone())
            .prop_map(|(sectors, origin)| DmTable::Linear(LinearTable { sectors, origin })),
        (
            any::<u64>(),
            origin.clone(),
            path.clone(),
            persistence(),
            any::<u64>()
        )
            .prop_map(|(sectors, origin, cow, persistence, chunk)| {
                DmTable::Snapshot(SnapshotTable {
                    sectors,
                    origin,
                    cow,
                    persistence,
                    chunk,
                })
            }),
        (any::<u64>(), path.clone(), path, any::<u64>(), any::<u64>()).prop_map(
            |(sectors, metadata, data, block_sectors, low_water)| {
                DmTable::ThinPool(ThinPoolTable {
                    sectors,
                    metadata,
                    data,
                    block_sectors,
                    low_water,
                })
            }
        ),
        (any::<u64>(), dm_name(), thin_id(), prop::option::of(origin)).prop_map(
            |(sectors, pool, id, origin)| DmTable::Thin(ThinTable {
                sectors,
                pool,
                id,
                origin,
            })
        ),
    ]
}

fn loop_path() -> impl Strategy<Value = DevPath> {
    any::<u32>().prop_map(|n| LoopDevNum::from(n).path().unwrap().try_into().unwrap())
}

#[proptest(ProptestConfig::with_cases(2048))]
fn the_kernel_opens_exactly_the_operands_of_any_constructible_table(
    #[strategy(table(dev_path().boxed()))] t: DmTable,
) {
    prop_assert_eq!(
        kernel_argv(&t.to_string()),
        escaped(operands(&t)),
        "{:?}",
        t.to_string()
    );
}

#[proptest(ProptestConfig::with_cases(2048))]
fn tables_of_dm_names_and_loop_devices_are_kernel_faithful(
    #[strategy(table(loop_path().boxed()))] t: DmTable,
) {
    prop_assert_eq!(kernel_argv(&t.to_string()), escaped(operands(&t)));
}

#[proptest]
fn a_thin_message_reaches_the_kernel_as_exactly_its_words(
    #[strategy(thin_id())] a: ThinId,
    #[strategy(thin_id())] b: ThinId,
) {
    for (m, words) in [
        (ThinMessage::CreateThin(a), vec![num("create_thin"), num(a)]),
        (
            ThinMessage::CreateSnap { id: a, origin: b },
            vec![num("create_snap"), num(a), num(b)],
        ),
        (ThinMessage::Delete(a), vec![num("delete"), num(a)]),
        (
            ThinMessage::ReserveMetadataSnap,
            vec![num("reserve_metadata_snap")],
        ),
        (
            ThinMessage::ReleaseMetadataSnap,
            vec![num("release_metadata_snap")],
        ),
    ] {
        prop_assert_eq!(kernel_argv(&m.to_string()), escaped(words));
    }
}

#[rstest]
#[case::no_break_space("/srv/hyper/x\u{a0}")]
#[case::latin_a_grave("/srv/hyper/\u{e0}.img")]
#[case::three_byte_char("/srv/hyper/\u{8a0}")]
#[case::unicode_whitespace("/srv/hyper/x\u{3000}")]
fn a_path_holding_a_token_separator_is_refused(#[case] path: &str) {
    assert!(path.parse::<DevPath>().is_err(), "{path:?}");
}
