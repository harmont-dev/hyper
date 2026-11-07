// SPDX-License-Identifier: MIT
//! Utility for deciding whether the program is running in insecure mode.
//!
//! Insecure mode is enabled by both building with the `insecure_mode` flag, as well as
//! setting `$HYPER_SETUIDHELPER_IS_INSECURE_MODE`.
//!
//! Insecure mode is designed to help make testing easier. The only public function you should use
//! is [`select`]. Callers control the semantics of what "insecure" means.
use std::sync::LazyLock;

const INSECURE_MODE_ENV: &str = "HYPER_SETUIDHELPER_IS_INSECURE_MODE";

static INSECURE: LazyLock<bool> = LazyLock::new(|| {
    let insecure =
        cfg!(feature = "insecure_mode") && std::env::var(INSECURE_MODE_ENV).as_deref() == Ok("1");

    if insecure {
        eprintln!(
            "hyper-suidhelper: WARNING: running in INSECURE TEST MODE \
             ({INSECURE_MODE_ENV}=1); never do this on a real host"
        );
    }

    insecure
});

/// Run `secure` in production; run `insecure` in testing.
pub fn select<T>(secure: impl FnOnce() -> T, insecure: impl FnOnce() -> T) -> T {
    if cfg!(feature = "insecure_mode") && *INSECURE {
        insecure()
    } else {
        secure()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use rstest::rstest;

    #[cfg(not(feature = "insecure_mode"))]
    #[rstest]
    fn secure_arm_always_taken_without_feature() {
        std::env::set_var(INSECURE_MODE_ENV, "1");
        assert_eq!(select(|| "secure", || "insecure"), "secure");
    }

    #[cfg(feature = "insecure_mode")]
    #[rstest]
    #[case::env_absent(None, "secure")]
    #[case::env_exactly_one(Some("1"), "insecure")]
    #[case::env_not_exactly_one(Some("true"), "secure")]
    fn feature_on_selects_by_env(#[case] env: Option<&str>, #[case] expected: &str) {
        match env {
            Some(value) => std::env::set_var(INSECURE_MODE_ENV, value),
            None => std::env::remove_var(INSECURE_MODE_ENV),
        }
        assert_eq!(select(|| "secure", || "insecure"), expected);
    }
}
