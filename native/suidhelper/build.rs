// SPDX-License-Identifier: MIT
//! Build guard: keep the `insecure_mode` feature out of any release
//! artifact. Tests build in the `debug` profile, so they are unaffected.

fn main() {
    // Re-run only when the relevant inputs change.
    println!("cargo:rerun-if-changed=build.rs");

    if std::env::var_os("CARGO_FEATURE_INSECURE_MODE").is_some() {
        println!(
            "cargo:warning=hyper-suidhelper built with `insecure_mode` \
             — TEST ONLY. Never install this binary setuid."
        );
        if std::env::var("PROFILE").as_deref() == Ok("release") {
            panic!(
                "refusing to build a RELEASE binary with `insecure_mode`: \
                 it would ship a setuid security bypass"
            );
        }
    }
}
