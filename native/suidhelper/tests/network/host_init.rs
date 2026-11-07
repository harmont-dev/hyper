//! `ip_forward_enabled` is the pure predicate `host_init` uses to decide
//! whether `/proc/sys/net/ipv4/ip_forward` says forwarding is on. Law under
//! test: it is `true` exactly for `"1"` modulo surrounding whitespace, and
//! `false` for everything else (kernel default `"0"`, empty, garbage).
use hyper_suidhelper::network::host_init::ip_forward_enabled;
use pretty_assertions::assert_eq;
use proptest::prelude::*;
use rstest::rstest;
use test_strategy::proptest;

#[rstest]
#[case::bare_one("1", true)]
#[case::one_with_trailing_newline("1\n", true)]
#[case::bare_zero("0", false)]
#[case::zero_with_trailing_newline("0\n", false)]
#[case::empty("", false)]
fn ip_forward_enabled_reads_the_proc_value(#[case] contents: &str, #[case] enabled: bool) {
    assert_eq!(ip_forward_enabled(contents), enabled);
}

#[proptest]
fn whitespace_padding_around_one_is_still_enabled(
    #[strategy("[ \t\n]{0,4}")] leading: String,
    #[strategy("[ \t\n]{0,4}")] trailing: String,
) {
    let contents = format!("{leading}1{trailing}");
    prop_assert!(ip_forward_enabled(&contents));
}

#[proptest]
fn anything_but_one_after_trim_is_disabled(#[strategy("[0-9]{2,4}")] digits: String) {
    // Multi-digit strings never equal the literal "1" after trimming.
    prop_assert!(!ip_forward_enabled(&digits));
}
