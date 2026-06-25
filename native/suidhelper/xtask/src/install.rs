//! Install the stamped binary setuid-root.
//!
//! Always stamps first (via [`crate::stamp`]) so an unstamped binary can never
//! be installed.

const INSTALL_PATH: &str = "/usr/local/bin/hyper-suidhelper";

/// Stamp, then install the binary setuid-root via `sudo install`.
pub fn run() {
    let path = crate::stamp::run();
    let status = std::process::Command::new("sudo")
        .args(["install", "-o", "root", "-g", "root", "-m", "4755"])
        .arg(&path)
        .arg(INSTALL_PATH)
        .status()
        .expect("failed to spawn sudo install");
    assert!(status.success(), "install failed");
    println!("installed {INSTALL_PATH} (setuid root)");
}
