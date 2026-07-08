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
