use hyper_guest_agent::init::resolver_from_cmdline;
use std::net::Ipv4Addr;

#[test]
fn present_among_other_params() {
    let cmdline = "reboot=k panic=1 hyper.resolver=1.1.1.1 ip=172.30.0.2::172.30.0.1:255.255.255.252::eth0:off";
    assert_eq!(
        resolver_from_cmdline(cmdline),
        Some(Ipv4Addr::new(1, 1, 1, 1))
    );
}

#[test]
fn absent_is_none() {
    let cmdline = "reboot=k panic=1 ip=172.30.0.2::172.30.0.1:255.255.255.252::eth0:off";
    assert_eq!(resolver_from_cmdline(cmdline), None);
}

#[test]
fn empty_cmdline_is_none() {
    assert_eq!(resolver_from_cmdline(""), None);
}

#[test]
fn empty_value_is_none() {
    assert_eq!(resolver_from_cmdline("hyper.resolver= ip=foo"), None);
}

#[test]
fn non_ipv4_value_is_none() {
    assert_eq!(resolver_from_cmdline("hyper.resolver=not-an-ip"), None);
}

#[test]
fn first_of_multiple_tokens_wins() {
    let cmdline = "hyper.resolver=1.1.1.1 hyper.resolver=8.8.8.8";
    assert_eq!(
        resolver_from_cmdline(cmdline),
        Some(Ipv4Addr::new(1, 1, 1, 1))
    );
}

#[test]
fn first_of_multiple_tokens_wins_among_other_params() {
    let cmdline = "a hyper.resolver=1.1.1.1 b hyper.resolver=8.8.8.8 c";
    assert_eq!(
        resolver_from_cmdline(cmdline),
        Some(Ipv4Addr::new(1, 1, 1, 1))
    );
}

// Regression: split_whitespace() + strip_prefix() requires the param to be its
// own whitespace-delimited token, not merely a substring anywhere on the
// cmdline. A future refactor to `cmdline.contains("hyper.resolver=")` would
// match this look-alike token and could point the guest at an attacker
// resolver embedded in an unrelated kernel param — that must never happen.
#[test]
fn prefixed_look_alike_token_is_not_matched() {
    assert_eq!(resolver_from_cmdline("xhyper.resolver=9.9.9.9"), None);
}

#[test]
fn suffixed_look_alike_key_is_not_matched() {
    assert_eq!(resolver_from_cmdline("hyper.resolverX=1.1.1.1"), None);
}
