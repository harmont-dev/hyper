//! The dm table and thin-message grammars are the text the helper hands to
//! `dmsetup` as root, so their render/parse pair is a wire contract. Laws:
//!   * parsing is total: arbitrary token soup never panics, it is accepted or
//!     refused;
//!   * whatever parses renders canonically: `parse(render(parse(s))) ==
//!     parse(s)`, and the render has exactly the arity of its target;
//!   * every value we can construct renders to text that parses back to the
//!     same value, so no operand can smuggle in an extra token or change which
//!     operand is a dm device (`devices`) versus a backing path (`paths`);
//!   * a thin message renders to at most three tokens and round-trips.

use hyperrs_linux::dm::{
    DevPath, DmName, DmTable, LinearTable, Origin, Persistence, Role, SnapshotTable, ThinMessage,
    ThinPoolTable, ThinTable,
};
use proptest::prelude::*;
use std::path::PathBuf;
use test_strategy::proptest;

fn arity(t: &DmTable) -> usize {
    match t {
        DmTable::Linear(_) => 5,
        DmTable::Snapshot(_) | DmTable::ThinPool(_) => 7,
        DmTable::Thin(ThinTable { origin, .. }) => 5 + usize::from(origin.is_some()),
    }
}

fn token() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("0".to_string()),
        Just("linear".to_string()),
        Just("snapshot".to_string()),
        Just("thin-pool".to_string()),
        Just("thin".to_string()),
        Just("P".to_string()),
        Just("N".to_string()),
        Just("/dev/mapper/hyper-a".to_string()),
        Just("/dev/mapper/".to_string()),
        Just("/dev/mapper".to_string()),
        Just("/dev/mapper/control".to_string()),
        Just("/srv/hyper/a.img".to_string()),
        Just("/srv/./a".to_string()),
        Just("7:0".to_string()),
        "[0-9]{1,22}",
        "[+-]?[0-9]{1,4}",
        "/[a-z]{1,4}(/[a-z.]{1,4}){0,3}/?",
        "\\PC{1,6}",
    ]
}

fn soup() -> impl Strategy<Value = String> {
    prop::collection::vec(token(), 0..9).prop_map(|t| t.join(" "))
}

#[proptest(ProptestConfig::with_cases(4096))]
fn parse_is_total_and_whatever_parses_renders_canonically(#[strategy(soup())] s: String) {
    if let Ok(t) = s.parse::<DmTable>() {
        let rendered = t.to_string();
        prop_assert_eq!(rendered.split(' ').count(), arity(&t), "{}", rendered);
        let back: DmTable = rendered.parse().unwrap();
        prop_assert_eq!(&back, &t);
        prop_assert_eq!(back.to_string(), rendered);
    }
}

fn component(chars: &'static str) -> impl Strategy<Value = String> {
    prop::collection::vec(
        prop::sample::select(chars.chars().collect::<Vec<_>>()),
        1..6,
    )
    .prop_map(String::from_iter)
    .prop_filter("dot component", |c| c != "." && c != "..")
}

const WIDE: &str = "abz09._-:=@#+~é\u{a0}\u{85}\u{2028}\u{3000}\u{feff}\u{1680}";

fn dev_path(chars: &'static str) -> impl Strategy<Value = DevPath> {
    prop::collection::vec(component(chars), 1..4).prop_filter_map("not strict", |parts| {
        PathBuf::from(format!("/{}", parts.join("/")))
            .try_into()
            .ok()
    })
}

fn dm_name() -> impl Strategy<Value = DmName> {
    "hyper-[a-z0-9]{1,8}".prop_map(|s| s.parse().unwrap())
}

fn origin(chars: &'static str) -> impl Strategy<Value = Origin> {
    prop_oneof![
        dm_name().prop_map(Origin::Device),
        dev_path(chars).prop_map(Origin::Path),
    ]
}

fn table(chars: &'static str) -> impl Strategy<Value = DmTable> {
    let persistence = prop_oneof![Just(Persistence::Persistent), Just(Persistence::Transient)];
    prop_oneof![
        (any::<u64>(), origin(chars))
            .prop_map(|(sectors, origin)| DmTable::Linear(LinearTable { sectors, origin })),
        (
            any::<u64>(),
            origin(chars),
            dev_path(chars),
            persistence,
            any::<u64>()
        )
            .prop_map(
                |(sectors, origin, cow, persistence, chunk)| DmTable::Snapshot(SnapshotTable {
                    sectors,
                    origin,
                    cow,
                    persistence,
                    chunk,
                })
            ),
        (
            any::<u64>(),
            dev_path(chars),
            dev_path(chars),
            any::<u64>(),
            any::<u64>()
        )
            .prop_map(|(sectors, metadata, data, block_sectors, low_water)| {
                DmTable::ThinPool(ThinPoolTable {
                    sectors,
                    metadata,
                    data,
                    block_sectors,
                    low_water,
                })
            }),
        (
            any::<u64>(),
            dm_name(),
            0u32..=hyperrs_linux::dm::ThinId::MAX,
            prop::option::of(origin(chars))
        )
            .prop_map(|(sectors, pool, id, origin)| DmTable::Thin(ThinTable {
                sectors,
                pool,
                id: hyperrs_linux::dm::ThinId::new(id).unwrap(),
                origin,
            })),
    ]
}

#[proptest(ProptestConfig::with_cases(2048))]
fn any_constructible_table_round_trips_through_its_rendering(#[strategy(table(WIDE))] t: DmTable) {
    let rendered = t.to_string();
    let back = rendered.parse::<DmTable>();
    prop_assert!(
        back.is_ok(),
        "{:?} does not parse back: {:?}",
        rendered,
        back
    );
    prop_assert_eq!(back.unwrap(), t);
}

#[proptest]
fn a_path_under_dev_mapper_is_only_ever_a_dm_device(#[strategy(dm_name())] name: DmName) {
    let path = PathBuf::from(format!("/dev/mapper/{name}"));
    prop_assert!(DevPath::try_from(path).is_err());

    let t = DmTable::Linear(LinearTable {
        sectors: 8,
        origin: Origin::Device(name.clone()),
    });
    let back: DmTable = t.to_string().parse().unwrap();
    prop_assert_eq!(
        back.paths().map(|(role, _)| role).collect::<Vec<Role>>(),
        []
    );
    prop_assert_eq!(back.devices().collect::<Vec<_>>(), [&name]);
}

#[proptest]
fn origin_text_round_trips(#[strategy(origin("abz09._-:=@#+"))] o: Origin) {
    let back: Origin = o.to_string().parse().unwrap();
    prop_assert_eq!(back, o);
}

fn message_token() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("create_thin".to_string()),
        Just("create_snap".to_string()),
        Just("delete".to_string()),
        Just("reserve_metadata_snap".to_string()),
        Just("release_metadata_snap".to_string()),
        Just("16777215".to_string()),
        Just("16777216".to_string()),
        "[+-]?0{0,3}[0-9]{1,9}",
        "\\PC{1,4}",
    ]
}

#[proptest(ProptestConfig::with_cases(4096))]
fn every_accepted_message_renders_to_a_canonical_short_command(
    #[strategy(prop::collection::vec(message_token(), 0..5))] tokens: Vec<String>,
) {
    let s = tokens.join(" ");
    if let Ok(m) = s.parse::<ThinMessage>() {
        let rendered = m.to_string();
        prop_assert!(rendered.split(' ').count() <= 3, "{}", rendered);
        prop_assert!(
            rendered.split(' ').skip(1).all(|tok| tok
                .parse::<u32>()
                .is_ok_and(|n| n <= hyperrs_linux::dm::ThinId::MAX && n.to_string() == tok)),
            "{}",
            rendered
        );
        prop_assert_eq!(rendered.parse::<ThinMessage>().unwrap(), m);
    }
}
