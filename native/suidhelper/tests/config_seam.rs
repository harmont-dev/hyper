//! The config-path seam routes through insecure_mode::select. With both gates
//! open, safe_load reads HYPER_SETUIDHELPER_CONFIG_PATH instead of the hardcoded
//! /etc/hyper/config.toml — but with every production check (SafePath lexical
//! gate, SafeFile ownership/type) still enforced. A `..` override is rejected by
//! the real SafePath gate as LooseComponents; the default path is lexically
//! clean, so that error proves the override (not the default) was used. No root
//! needed and no security check is bypassed.
#![cfg(feature = "insecure_mode")]

use hyper_suidhelper::config::{Config, LoadingError};
use hyper_suidhelper::fs::path::{ComponentError, ValidationError};

#[test]
fn override_path_is_consulted_through_the_real_lexical_gate() {
    let loose = "/tmp/hyper-suidhelper/../escape.toml";
    std::env::set_var("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1");
    std::env::set_var("HYPER_SETUIDHELPER_CONFIG_PATH", loose);

    let err = Config::safe_load().expect_err("override must be consulted");
    assert!(
        matches!(
            err,
            LoadingError::Path(ValidationError::Component(ComponentError::ParentDir))
        ),
        "expected the override path to hit the real lexical gate, got {err:?}",
    );
}
