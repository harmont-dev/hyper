// SPDX-License-Identifier: AGPL-3.0-only
//! Central security gate: the single place that decides whether this process is
//! running in INSECURE TEST MODE, resolved once at startup.
//!
//! Two independent gates, both required to open the insecure path:
//!   1. compile-time — the `insecure_test_seams` Cargo feature. Never enabled in
//!      release; `build.rs` refuses a release build with it on.
//!   2. runtime — `HYPER_SETUIDHELPER_IS_INSECURE_MODE=1` in the environment.
//!
//! Seams never test these directly. They call [`split`], which pairs every
//! insecure branch with its production default and can only run the insecure arm
//! when BOTH gates are open. The default — uninitialized, or any release build —
//! is always the secure arm, so a forgotten `init` fails safe.

use std::sync::atomic::{AtomicBool, Ordering};

const INSECURE_MODE_ENV: &str = "HYPER_SETUIDHELPER_IS_INSECURE_MODE";

/// Resolved once by [`init`]; defaults to secure so a missing `init` is safe.
static INSECURE: AtomicBool = AtomicBool::new(false);

/// Resolve the gate from the compile feature and the environment. Call once, as
/// the very first thing in `main`, before any seam (e.g. the config load) runs.
/// Idempotent.
pub fn init() {
    let insecure = cfg!(feature = "insecure_test_seams") && env_opts_in();
    if insecure {
        eprintln!(
            "hyper-suidhelper: WARNING: running in INSECURE TEST MODE \
             ({INSECURE_MODE_ENV}=1); never do this on a real host"
        );
    }
    // Relaxed is sufficient: a standalone flag, written once at startup before
    // any concurrency, and it publishes no other memory — so there is no
    // acquire/release (let alone total-order) relationship to enforce.
    INSECURE.store(insecure, Ordering::Relaxed);
}

fn env_opts_in() -> bool {
    std::env::var(INSECURE_MODE_ENV).as_deref() == Ok("1")
}

/// Run `secure` in production; run `insecure` only when BOTH gates are open.
///
/// The `cfg!(feature = ...)` is a compile-time constant: in any build without
/// the feature it folds to `false`, so the whole condition is constant-false and
/// the optimizer drops the `insecure` branch entirely.
pub fn split<T>(secure: impl FnOnce() -> T, insecure: impl FnOnce() -> T) -> T {
    if cfg!(feature = "insecure_test_seams") && INSECURE.load(Ordering::Relaxed) {
        insecure()
    } else {
        secure()
    }
}
