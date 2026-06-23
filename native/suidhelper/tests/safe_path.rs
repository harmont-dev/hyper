//! Property tests for the lexical confinement gate. These run against the
//! `hyper_suidhelper` library crate (Task 6's lib split), not inline in source.

use hyper_suidhelper::util::safe_path::{IsAbsolute, SafePath, StrictComponents, ValidationError};
use proptest::prelude::*;
use std::path::PathBuf;

// The fully-enforced flavor used at every real call site.
type Strict = SafePath<IsAbsolute, StrictComponents>;

// A plain, safe path component: no `.`/`..`/`/`/empty.
fn safe_component() -> impl Strategy<Value = String> {
    "[a-z][a-z0-9_]{0,7}"
}

// A component that must make StrictComponents reject the whole path.
fn loose_component() -> impl Strategy<Value = String> {
    prop_oneof![
        Just(".".to_string()),
        Just("..".to_string()),
        Just("".to_string())
    ]
}

fn join_abs(parts: &[String]) -> PathBuf {
    let mut p = PathBuf::from("/");
    for part in parts {
        p.push(part);
    }
    p
}

proptest! {
    // An absolute path of only plain components is always accepted.
    #[test]
    fn accepts_clean_absolute_paths(parts in prop::collection::vec(safe_component(), 1..6)) {
        let path = join_abs(&parts);
        prop_assert!(Strict::try_from(path).is_ok());
    }

    // A path containing ANY `.`/`..`/empty component is always rejected.
    // (This is the confinement guarantee: `..`, `.`, and `//` never slip through.)
    #[test]
    fn rejects_any_loose_component(
        prefix in prop::collection::vec(safe_component(), 0..4),
        bad in loose_component(),
        suffix in prop::collection::vec(safe_component(), 0..4),
    ) {
        let mut parts = prefix;
        parts.push(bad);
        parts.extend(suffix);
        // Build the path from a RAW string, not via PathBuf::push: pushing an empty
        // component collapses it to a bare separator, hiding the `//` we want to
        // test. Raw joining makes `.`, `..`, and empty (`//`) literally present.
        let path = PathBuf::from(format!("/{}", parts.join("/")));
        prop_assert!(matches!(
            Strict::try_from(path),
            Err(ValidationError::LooseComponents)
        ));
    }

    // A non-absolute path is always rejected on the absoluteness axis.
    #[test]
    fn rejects_relative_paths(parts in prop::collection::vec(safe_component(), 1..6)) {
        let rel: PathBuf = parts.iter().collect();
        prop_assert!(matches!(
            Strict::try_from(rel),
            Err(ValidationError::NotAbsolute)
        ));
    }

    // relative_to reconstructs the original: base ++ parents ++ leaf == path.
    #[test]
    fn relative_to_round_trips(
        base_parts in prop::collection::vec(safe_component(), 1..4),
        rel_parts in prop::collection::vec(safe_component(), 1..5),
    ) {
        let base = join_abs(&base_parts);
        let full_parts: Vec<String> =
            base_parts.iter().chain(rel_parts.iter()).cloned().collect();
        let full = join_abs(&full_parts);

        let safe = Strict::try_from(full.clone()).unwrap();
        let (parents, leaf) = safe.relative_to(&base).unwrap();

        let mut rebuilt = base.clone();
        for p in &parents {
            rebuilt.push(p);
        }
        rebuilt.push(&leaf);
        prop_assert_eq!(rebuilt, full);

        // The decomposed pieces are exactly the relative components.
        let mut decomposed: Vec<String> =
            parents.iter().map(|p| p.to_string_lossy().into_owned()).collect();
        decomposed.push(leaf.to_string_lossy().into_owned());
        prop_assert_eq!(decomposed, rel_parts);
    }

    // A path that is not under `base` is rejected, never silently decomposed.
    #[test]
    fn relative_to_rejects_paths_outside_base(
        base_parts in prop::collection::vec(safe_component(), 1..4),
        other_parts in prop::collection::vec(safe_component(), 1..4),
    ) {
        // Force divergence at the first component so `other` cannot be under `base`.
        let base = join_abs(&base_parts);
        let mut other = vec!["zzdifferent".to_string()];
        other.extend(other_parts);
        let path = join_abs(&other);

        let safe = Strict::try_from(path).unwrap();
        prop_assert!(matches!(
            safe.relative_to(&base),
            Err(ValidationError::NotUnderBase)
        ));
    }

    // A path equal to the base has no leaf component.
    #[test]
    fn relative_to_base_itself_has_no_leaf(
        base_parts in prop::collection::vec(safe_component(), 1..4),
    ) {
        let base = join_abs(&base_parts);
        let safe = Strict::try_from(base.clone()).unwrap();
        prop_assert!(matches!(
            safe.relative_to(&base),
            Err(ValidationError::NoLeaf)
        ));
    }
}
