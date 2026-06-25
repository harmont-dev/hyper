//! The config-path seam routes through security_gate::split. With both gates
//! open, safe_load consults HYPER_SETUIDHELPER_CONFIG_PATH. This negative case
//! needs no root: pointing at an absent file yields `Unreadable(<that path>)`,
//! proving the override path — not /etc/hyper — was used.
#![cfg(feature = "insecure_test_seams")]

use hyper_suidhelper::config::{Config, LoadingError};
use hyper_suidhelper::security_gate;
use std::path::PathBuf;

#[test]
fn override_path_is_consulted_when_gates_open() {
    let missing = "/tmp/hyper-suidhelper-no-such-config-42.toml";
    std::env::set_var("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1");
    std::env::set_var("HYPER_SETUIDHELPER_CONFIG_PATH", missing);
    security_gate::init();

    let err = Config::safe_load().expect_err("absent override file must fail");
    assert!(
        matches!(err, LoadingError::Unreadable(ref p) if p == &PathBuf::from(missing)),
        "expected Unreadable({missing:?}), got {err:?}",
    );
}
