//! The helper's JSON requests deserialize straight into these types, so serde
//! must be exactly as strict as the checked constructors. Laws:
//!   * a JSON integer is a `ThinId` iff it is in `0..=ThinId::MAX`, and it
//!     keeps its value; any non-integer JSON is refused;
//!   * a JSON string deserializes to a `DmName`, `LoopDevNum` or `Origin`
//!     exactly when `FromStr` accepts it, and to the same value.
#![cfg(feature = "serde")]

use hyperrs_linux::dm::{DmName, Origin, ThinId};
use hyperrs_linux::loopdev::LoopDevNum;
use proptest::prelude::*;
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::fmt::Debug;
use std::str::FromStr;
use test_strategy::proptest;

#[proptest]
fn a_json_integer_is_a_thin_id_exactly_when_it_fits_24_bits(
    #[strategy(prop_oneof![
        0i64..=i64::from(ThinId::MAX),
        (i64::from(ThinId::MAX) + 1)..=i64::MAX,
        i64::MIN..0,
    ])]
    n: i64,
) {
    let got = serde_json::from_value::<ThinId>(json!(n));
    if (0..=i64::from(ThinId::MAX)).contains(&n) {
        prop_assert_eq!(u64::from(got.unwrap()), n as u64);
    } else {
        prop_assert!(got.is_err(), "accepted {}", n);
    }
}

#[proptest]
fn non_integer_json_is_never_a_thin_id(
    #[strategy(prop_oneof![
        (0u32..1000).prop_map(|n| json!(f64::from(n) + 0.5)),
        (0u32..1000).prop_map(|n| json!(n.to_string())),
        Just(json!(null)),
        Just(json!(true)),
        Just(json!([1])),
        Just(json!({"id": 1})),
    ])]
    v: Value,
) {
    prop_assert!(
        serde_json::from_value::<ThinId>(v.clone()).is_err(),
        "accepted {}",
        v
    );
}

fn agrees_with_from_str<T>(s: &str) -> Result<(), TestCaseError>
where
    T: DeserializeOwned + FromStr + PartialEq + Debug,
    T::Err: Debug,
{
    let wire = serde_json::from_value::<T>(json!(s));
    match s.parse::<T>() {
        Ok(parsed) => prop_assert_eq!(wire.unwrap(), parsed),
        Err(_) => prop_assert!(wire.is_err(), "wire accepted {:?} that FromStr refuses", s),
    }
    Ok(())
}

fn text() -> impl Strategy<Value = String> {
    prop_oneof![
        "[a-z0-9#+.:=@_-]{0,12}",
        "hyper-[a-z0-9]{0,8}",
        "/dev/loop[0-9+-]{0,11}",
        "/dev/mapper/[a-z0-9./-]{0,10}",
        "/[a-z./]{0,12}",
        "\\PC{0,8}",
    ]
}

#[proptest(ProptestConfig::with_cases(1024))]
fn string_wire_types_deserialize_exactly_as_from_str(#[strategy(text())] s: String) {
    agrees_with_from_str::<DmName>(&s)?;
    agrees_with_from_str::<LoopDevNum>(&s)?;
    agrees_with_from_str::<Origin>(&s)?;
}
