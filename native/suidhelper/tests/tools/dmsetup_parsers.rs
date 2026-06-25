//! `DmTable`/`ThinMessage` are reconstructed from the caller's string and then
//! re-rendered, so dmsetup only ever sees a table/message we rebuilt. The accept
//! set must round-trip to a canonical single-spaced form; the reject set covers
//! non-whitelisted targets, arbitrary (non loop / non hyper-) devices, and
//! malformed arity. These are the contract that keeps dmsetup off arbitrary
//! storage.

use hyper_suidhelper::tools::{DmTable, ThinMessage};

#[test]
fn accepts_canonical_tables_and_round_trips() {
    for s in [
        "0 100 snapshot /dev/loop0 /dev/loop1 P 8",
        "0 100 thin-pool /dev/loop0 /dev/loop1 128 1024",
        "0 100 thin /dev/mapper/hyper-pool 0",
        "0 100 thin /dev/mapper/hyper-pool 0 /dev/mapper/hyper-orig",
    ] {
        let t = s
            .parse::<DmTable>()
            .unwrap_or_else(|_| panic!("rejected {s:?}"));
        assert_eq!(t.to_string(), s, "round-trip changed {s:?}");
    }
}

#[test]
fn normalizes_inner_whitespace_on_render() {
    let weird = "0   100  snapshot  /dev/loop0   /dev/loop1 P 8";
    let canonical = "0 100 snapshot /dev/loop0 /dev/loop1 P 8";
    let t = weird
        .parse::<DmTable>()
        .expect("weird spacing must still parse");
    assert_eq!(t.to_string(), canonical);
}

#[test]
fn rejects_non_whitelisted_targets_and_devices() {
    for bad in [
        "0 100 linear /dev/loop0 0",                    // target not allowed
        "0 100 crypt /dev/loop0 /dev/loop1",            // target not allowed
        "0 100 snapshot /dev/sda /dev/loop1 P 8",       // origin = arbitrary storage
        "0 100 snapshot /dev/loop0 /dev/sda P 8",       // cow = arbitrary storage
        "0 100 snapshot /dev/loop0 /dev/loop1 X 8",     // bad persistence flag
        "1 100 snapshot /dev/loop0 /dev/loop1 P 8",     // start != 0
        "0 100 snapshot /dev/loop0 /dev/loop1 P",       // too few fields
        "0 100 thin-pool /dev/sda /dev/loop1 128 1024", // meta = arbitrary
        "0 100 thin /dev/sda 0",                        // pool = arbitrary
        "",                                             // empty
        "garbage",                                      // junk
    ] {
        assert!(bad.parse::<DmTable>().is_err(), "DmTable accepted {bad:?}");
    }
}

#[test]
fn thinmessage_accepts_whitelisted_and_normalizes() {
    for (s, canon) in [
        ("create_thin 7", "create_thin 7"),
        ("create_thin   7", "create_thin 7"),
        ("delete 3", "delete 3"),
    ] {
        let m = s
            .parse::<ThinMessage>()
            .unwrap_or_else(|_| panic!("rejected {s:?}"));
        assert_eq!(m.to_string(), canon, "round-trip changed {s:?}");
    }
}

#[test]
fn thinmessage_rejects_non_whitelisted() {
    for bad in [
        "resize 10",
        "create_thin",
        "delete",
        "delete x",
        "create_thin 1 2",
        "",
        "create_thin -1",
    ] {
        assert!(
            bad.parse::<ThinMessage>().is_err(),
            "ThinMessage accepted {bad:?}"
        );
    }
}
