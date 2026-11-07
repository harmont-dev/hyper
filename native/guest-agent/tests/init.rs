use hyper_guest_agent::init::resolver_from_cmdline;
use rstest::rstest;
use std::net::Ipv4Addr;

const ONE: Option<Ipv4Addr> = Some(Ipv4Addr::new(1, 1, 1, 1));

#[rstest]
#[case::present_among_other_params(
    "reboot=k panic=1 hyper.resolver=1.1.1.1 ip=172.30.0.2::172.30.0.1:255.255.255.252::eth0:off",
    ONE
)]
#[case::absent(
    "reboot=k panic=1 ip=172.30.0.2::172.30.0.1:255.255.255.252::eth0:off",
    None
)]
#[case::empty_cmdline("", None)]
#[case::empty_value("hyper.resolver= ip=foo", None)]
#[case::non_ipv4_value("hyper.resolver=not-an-ip", None)]
#[case::first_of_multiple_tokens_wins("hyper.resolver=1.1.1.1 hyper.resolver=8.8.8.8", ONE)]
#[case::first_of_multiple_tokens_wins_among_other_params(
    "a hyper.resolver=1.1.1.1 b hyper.resolver=8.8.8.8 c",
    ONE
)]
// Regression: split_whitespace() + strip_prefix() requires the param to be its
// own whitespace-delimited token, not merely a substring anywhere on the
// cmdline. A future refactor to `cmdline.contains("hyper.resolver=")` would
// match this look-alike token and could point the guest at an attacker
// resolver embedded in an unrelated kernel param — that must never happen.
#[case::prefixed_look_alike_token_is_not_matched("xhyper.resolver=9.9.9.9", None)]
#[case::suffixed_look_alike_key_is_not_matched("hyper.resolverX=1.1.1.1", None)]
fn resolver_from_cmdline_finds_the_first_hyper_resolver_token(
    #[case] cmdline: &str,
    #[case] expected: Option<Ipv4Addr>,
) {
    assert_eq!(resolver_from_cmdline(cmdline), expected);
}
