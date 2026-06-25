//! Gate-resolution contract for `security_gate`. nextest runs each test in its
//! own process, so the env mutations and the process-global `INSECURE` flag do
//! not race across tests.

use hyper_suidhelper::security_gate;

const ENV: &str = "HYPER_SETUIDHELPER_IS_INSECURE_MODE";

// Without the feature compiled in, the insecure arm is unreachable no matter
// what the environment says — this is the production guarantee.
#[cfg(not(feature = "insecure_test_seams"))]
#[test]
fn secure_arm_always_taken_without_feature() {
    std::env::set_var(ENV, "1");
    security_gate::init();
    assert_eq!(security_gate::split(|| "secure", || "insecure"), "secure");
}

// With the feature, the env var is still required: feature alone is not enough.
#[cfg(feature = "insecure_test_seams")]
#[test]
fn secure_arm_when_env_absent_even_with_feature() {
    std::env::remove_var(ENV);
    security_gate::init();
    assert_eq!(security_gate::split(|| "secure", || "insecure"), "secure");
}

// Both gates open → insecure arm.
#[cfg(feature = "insecure_test_seams")]
#[test]
fn insecure_arm_when_feature_and_env() {
    std::env::set_var(ENV, "1");
    security_gate::init();
    assert_eq!(security_gate::split(|| "secure", || "insecure"), "insecure");
}

// A wrong env value is not opt-in.
#[cfg(feature = "insecure_test_seams")]
#[test]
fn secure_arm_when_env_not_exactly_one() {
    std::env::set_var(ENV, "true");
    security_gate::init();
    assert_eq!(security_gate::split(|| "secure", || "insecure"), "secure");
}

// Default (init never called) is secure.
#[test]
fn secure_arm_before_init() {
    assert_eq!(security_gate::split(|| "secure", || "insecure"), "secure");
}
