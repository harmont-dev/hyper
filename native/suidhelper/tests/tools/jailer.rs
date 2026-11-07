//! Refusal contracts for the jailer's pure validators — the security core. A
//! valid input must round-trip to its canonical form; an invalid one must
//! *always* be rejected, never silently accepted. These properties are what stop
//! a compromised BEAM from naming uid 0, a privileged path, a traversal, or a
//! flag through the jailer subcommand.

use clap::{Args, FromArgMatches};
use hyper_suidhelper::tools::jailer::JailerArgs;
use rstest::rstest;

fn parse(limits: &[&str]) -> Result<JailerArgs, clap::Error> {
    parse_with_sock("/api.sock", limits)
}

fn parse_with_sock(api_sock: &str, limits: &[&str]) -> Result<JailerArgs, clap::Error> {
    let base = [
        "--id",
        "vm1",
        "--uid",
        "900001",
        "--gid",
        "900001",
        "--api-sock",
        api_sock,
    ];
    let matches = JailerArgs::augment_args(clap::Command::new("jailer").no_binary_name(true))
        .try_get_matches_from(base.iter().chain(limits))?;
    JailerArgs::from_arg_matches(&matches)
}

#[rstest]
#[case::none(&[], true)]
#[case::memory_max(&["--memory-max", "1048576"], true)]
#[case::cpu_quota_and_period(&["--cpu-quota-us", "50000", "--cpu-period-us", "100000"], true)]
#[case::all_minimal(&["--memory-max", "1", "--cpu-quota-us", "1", "--cpu-period-us", "1"], true)]
#[case::zero_memory(&["--memory-max", "0"], false)]
#[case::literal_max_memory(&["--memory-max", "max"], false)]
#[case::negative_memory(&["--memory-max", "-1"], false)]
#[case::suffixed_memory(&["--memory-max", "12x"], false)]
#[case::memory_past_u64(&["--memory-max", "18446744073709551616"], false)]
#[case::repeated_memory(&["--memory-max", "1", "--memory-max", "2"], false)]
#[case::quota_without_period(&["--cpu-quota-us", "50000"], false)]
#[case::period_without_quota(&["--cpu-period-us", "100000"], false)]
#[case::zero_quota(&["--cpu-quota-us", "0", "--cpu-period-us", "100000"], false)]
#[case::zero_period(&["--cpu-quota-us", "50000", "--cpu-period-us", "0"], false)]
#[case::repeated_quota(
    &["--cpu-quota-us", "1", "--cpu-quota-us", "2", "--cpu-period-us", "1"],
    false
)]
#[case::raw_cgroup(&["--cgroup", "memory.max=1"], false)]
fn cgroup_limits(#[case] limits: &[&str], #[case] accepted: bool) {
    assert_eq!(parse(limits).is_ok(), accepted, "{limits:?}");
}

#[rstest]
#[case::root_file("/api.socket", true)]
#[case::nested("/run/fc/api.socket", true)]
#[case::leading_dash("/-dash", true)]
#[case::empty("", false)]
#[case::relative("api.socket", false)]
#[case::parent_dir("/../etc/x", false)]
#[case::current_dir("/a/./b", false)]
#[case::double_slash("//x", false)]
#[case::trailing_slash("/a/", false)]
#[case::space("/a b", false)]
fn api_sock_must_be_a_strict_absolute_path(#[case] sock: &str, #[case] accepted: bool) {
    assert_eq!(parse_with_sock(sock, &[]).is_ok(), accepted, "{sock:?}");
}
