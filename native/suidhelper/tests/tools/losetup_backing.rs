//! Contracts of `ok_backing_file`, the losetup backing-file confinement gate.
//! Laws:
//!   * a path that does not canonicalize (absent file) is refused as
//!     `Canonicalize`, never accepted;
//!   * an existing path whose *resolved* real location is outside the
//!     configured data root is ALWAYS refused as `OutsideBase`, regardless of
//!     the spelling used to reach it (direct, symlink, `..` traversal);
//!   * (as-root, Task 2) an in-base regular file is accepted as an
//!     inheritable `/proc/self/fd/N` handle naming exactly the validated inode.
#![cfg(feature = "insecure_test_seams")]

use hyper_suidhelper::security_gate;
use hyper_suidhelper::tools::losetup::{ok_backing_file, Error};
use proptest::prelude::*;

// An absolute, lexically-strict path that never exists: `safe_load` sees
// ENOENT and falls back to the built-in defaults (hyper_base = /srv/hyper),
// making the base deterministic even on hosts that have a real
// /etc/hyper/config.toml.
const ABSENT_CONFIG: &str = "/hyper-suidhelper-test-absent/config.toml";

fn init_default_config() {
    std::env::set_var("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1");
    std::env::set_var("HYPER_SETUIDHELPER_CONFIG_PATH", ABSENT_CONFIG);
    security_gate::init();
}

proptest! {
    /// Any existing regular file outside the data root is refused as
    /// `OutsideBase`, whatever its name.
    #[test]
    fn any_existing_file_outside_base_is_refused(
        name in "[A-Za-z0-9][A-Za-z0-9._-]{0,31}",
    ) {
        init_default_config();
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join(&name);
        std::fs::write(&p, b"x").unwrap();

        let err = ok_backing_file(p.to_str().unwrap())
            .expect_err("out-of-base backing file accepted");
        prop_assert!(matches!(err, Error::OutsideBase { .. }), "got {err:?}");
    }
}

#[test]
fn absent_path_is_refused_as_canonicalize() {
    init_default_config();
    let tmp = tempfile::tempdir().unwrap();
    let absent = tmp.path().join("nope.img");

    let err = ok_backing_file(absent.to_str().unwrap()).expect_err("absent backing file accepted");
    assert!(matches!(err, Error::Canonicalize { .. }), "got {err:?}");
}

#[test]
fn refusal_is_decided_on_the_resolved_path() {
    init_default_config();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("target.img");
    std::fs::write(&target, b"x").unwrap();

    // A symlink and a `..` traversal both resolve to the same out-of-base
    // inode; the resolved path (not the spelling) must decide.
    let link = tmp.path().join("link.img");
    std::os::unix::fs::symlink(&target, &link).unwrap();
    std::fs::create_dir(tmp.path().join("sub")).unwrap();
    let dotdot = format!("{}/sub/../target.img", tmp.path().display());

    for spelling in [link.to_str().unwrap(), &dotdot] {
        let err = ok_backing_file(spelling).expect_err("out-of-base spelling accepted");
        assert!(
            matches!(err, Error::OutsideBase { .. }),
            "{spelling}: got {err:?}",
        );
    }
}
