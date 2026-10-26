//! `DmTable`/`ThinMessage` are reconstructed from the caller's string and then
//! re-rendered, so dmsetup only ever sees a table/message we rebuilt. The accept
//! set must round-trip to a canonical single-spaced form; the reject set covers
//! non-whitelisted targets, arbitrary (non loop / non hyper-) devices, and
//! malformed arity. These are the contract that keeps dmsetup off arbitrary
//! storage.

use hyper_suidhelper::linux::dm::ThinId;
use hyper_suidhelper::tools::{parse_message, parse_table, ThinMessage};

fn id(n: u32) -> ThinId {
    ThinId::new(n).unwrap()
}

#[test]
fn accepts_canonical_tables_and_round_trips() {
    for s in [
        "0 100 snapshot /dev/loop0 /dev/loop1 P 8",
        "0 100 thin-pool /dev/loop0 /dev/loop1 128 1024",
        "0 100 thin /dev/mapper/hyper-pool 0",
        "0 100 thin /dev/mapper/hyper-pool 0 /dev/mapper/hyper-orig",
        "0 100 thin /dev/mapper/hyper-pool 16777215",
    ] {
        let t = parse_table(s).unwrap_or_else(|_| panic!("rejected {s:?}"));
        assert_eq!(t.to_string(), s, "round-trip changed {s:?}");
    }
}

#[test]
fn normalizes_inner_whitespace_on_render() {
    let weird = "0   100  snapshot  /dev/loop0   /dev/loop1 P 8";
    let canonical = "0 100 snapshot /dev/loop0 /dev/loop1 P 8";
    let t = parse_table(weird).expect("weird spacing must still parse");
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
        "0 100 thin /dev/mapper/hyper-pool 16777216",   // id past 24 bits
        "0 100 thin /dev/mapper/hyper-pool 0 /dev/sda", // origin = arbitrary
        "0 100 thin /dev/mapper/hyper-pool 0 /dev/loop0 /dev/loop1", // two origins
        "",                                             // empty
        "garbage",                                      // junk
    ] {
        assert!(parse_table(bad).is_err(), "parse_table accepted {bad:?}");
    }
}

#[test]
fn thinmessage_accepts_whitelisted_and_normalizes() {
    for (s, want) in [
        ("create_thin 7", ThinMessage::CreateThin(id(7))),
        ("create_thin   7", ThinMessage::CreateThin(id(7))),
        (
            "create_thin 16777215",
            ThinMessage::CreateThin(id(16777215)),
        ),
        ("delete 3", ThinMessage::Delete(id(3))),
        (
            "create_snap 4 2",
            ThinMessage::CreateSnap {
                id: id(4),
                origin: id(2),
            },
        ),
        (
            "create_snap   4   2",
            ThinMessage::CreateSnap {
                id: id(4),
                origin: id(2),
            },
        ),
        ("reserve_metadata_snap", ThinMessage::ReserveMetadataSnap),
        (
            "  reserve_metadata_snap  ",
            ThinMessage::ReserveMetadataSnap,
        ),
        ("release_metadata_snap", ThinMessage::ReleaseMetadataSnap),
    ] {
        let got = parse_message(s).unwrap_or_else(|_| panic!("rejected {s:?}"));
        assert_eq!(got, want, "{s:?}");
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
        "create_snap",
        "create_snap 1",
        "create_snap 1 2 3",
        "create_snap x 2",
        "create_snap 1 y",
        "create_snap -1 2",
        "reserve_metadata_snap 1",
        "release_metadata_snap 1 2",
        "reserve_metadata",
        "create_thin 16777216",
        "delete 16777216",
        "create_snap 1 16777216",
    ] {
        assert!(
            parse_message(bad).is_err(),
            "parse_message accepted {bad:?}"
        );
    }
}
