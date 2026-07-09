//! `ip_forward_enabled` is the pure predicate `host_init` uses to decide
//! whether `/proc/sys/net/ipv4/ip_forward` says forwarding is on. Law under
//! test: it is `true` exactly for `"1"` modulo surrounding whitespace, and
//! `false` for everything else (kernel default `"0"`, empty, garbage).
use hyper_suidhelper::tools::network::host_init::ip_forward_enabled;
use proptest::prelude::*;

#[test]
fn enabled_for_bare_one() {
    assert!(ip_forward_enabled("1"));
}

#[test]
fn enabled_for_one_with_trailing_newline() {
    assert!(ip_forward_enabled("1\n"));
}

#[test]
fn disabled_for_zero() {
    assert!(!ip_forward_enabled("0"));
    assert!(!ip_forward_enabled("0\n"));
}

#[test]
fn disabled_for_empty_contents() {
    assert!(!ip_forward_enabled(""));
}

proptest! {
    #[test]
    fn whitespace_padding_around_one_is_still_enabled(
        leading in "[ \t\n]{0,4}",
        trailing in "[ \t\n]{0,4}",
    ) {
        let contents = format!("{leading}1{trailing}");
        prop_assert!(ip_forward_enabled(&contents));
    }

    #[test]
    fn anything_but_one_after_trim_is_disabled(digits in "[0-9]{2,4}") {
        // Multi-digit strings never equal the literal "1" after trimming.
        prop_assert!(!ip_forward_enabled(&digits));
    }
}
