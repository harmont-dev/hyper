use hyper_suidhelper::firecracker::id::{IdError, RangeError, UidGidRange};
use nix::unistd::{Gid, Uid};
use proptest::prelude::*;

fn range() -> impl Strategy<Value = UidGidRange> {
    (1u32.., any::<u32>())
        .prop_map(|(min, span)| UidGidRange::try_from([min, min.saturating_add(span)]).unwrap())
}

proptest! {
    #[test]
    fn ordered_nonzero_pair_is_a_range(min in 1u32.., span in any::<u32>()) {
        let max = min.saturating_add(span);
        let r = UidGidRange::try_from([min, max]).unwrap();
        prop_assert_eq!((r.min(), r.max()), (min, max));
    }

    #[test]
    fn zero_min_is_never_a_range(max in any::<u32>()) {
        prop_assert_eq!(
            UidGidRange::try_from([0, max]),
            Err(RangeError { min: 0, max })
        );
    }

    #[test]
    fn inverted_pair_is_never_a_range(max in 0u32..u32::MAX, gap in 1u32..) {
        let min = max.saturating_add(gap);
        prop_assert_eq!(
            UidGidRange::try_from([min, max]),
            Err(RangeError { min, max })
        );
    }

    #[test]
    fn zero_is_never_minted(r in range()) {
        prop_assert!(r.uid(0).is_err());
        prop_assert!(r.gid(0).is_err());
    }

    #[test]
    fn in_range_id_is_minted_unchanged(r in range(), off in any::<u32>()) {
        let n = r.min() + off % (r.max() - r.min() + 1);
        prop_assert_eq!(Uid::from(r.uid(n).unwrap()), Uid::from_raw(n));
        prop_assert_eq!(Gid::from(r.gid(n).unwrap()), Gid::from_raw(n));
    }

    #[test]
    fn out_of_range_id_is_refused(r in range()) {
        let expected = |value| IdError { value, min: r.min(), max: r.max() };
        prop_assert_eq!(r.uid(r.min() - 1), Err(expected(r.min() - 1)));
        prop_assert_eq!(r.gid(r.min() - 1), Err(expected(r.min() - 1)));
        if let Some(above) = r.max().checked_add(1) {
            prop_assert_eq!(r.uid(above), Err(expected(above)));
            prop_assert_eq!(r.gid(above), Err(expected(above)));
        }
    }
}
