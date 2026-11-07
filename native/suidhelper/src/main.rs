//! Hyper's setuid helper which needs `root` access.
//!
//! This utility is immediately de-escalates its privilege from `root` to the calling user, but then
//! promotes itself to `root` as necessary.

hyperrs_process::setuid_main!(hyper_suidhelper::cli::Request::main);
