// SPDX-License-Identifier: AGPL-3.0-only
//! Build guard: keep the `insecure_test_seams` feature out of any release
//! artifact. Tests build in the `debug` profile, so they are unaffected.

fn main() {
    // Re-run only when the relevant inputs change.
    println!("cargo:rerun-if-changed=build.rs");

    if std::env::var_os("CARGO_FEATURE_INSECURE_TEST_SEAMS").is_some() {
        println!(
            "cargo:warning=hyper-suidhelper built with `insecure_test_seams` \
             — TEST ONLY. Never install this binary setuid."
        );
        if std::env::var("PROFILE").as_deref() == Ok("release") {
            panic!(
                "refusing to build a RELEASE binary with `insecure_test_seams`: \
                 it would ship a setuid security bypass"
            );
        }
    }
}
