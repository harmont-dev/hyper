//! A real setuid-root install of the static insecure-mode helper, driven by a non-root member of
//! its group, optionally inside a private mount namespace whose `/run` is a fresh tmpfs, so the
//! helper's fixed `/run/hyper-suidhelper` lock dir can be staged hostile without touching the
//! host's.

// Each [[test]] target compiles its own copy of this module and not every target uses every item.
#![allow(dead_code)]

use assert_fs::TempDir;
use nix::unistd::{Gid, Uid};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;

const MANIFEST_DIR: &str = env!("CARGO_MANIFEST_DIR");

pub const INSTALL_GROUP: u32 = 62_001;

#[derive(Clone, Copy, Debug)]
pub struct Caller {
    pub uid: u32,
    pub gid: u32,
    pub groups: &'static [u32],
}

pub const MEMBER: Caller = Caller {
    uid: 62_010,
    gid: INSTALL_GROUP,
    groups: &[],
};

pub const OTHER_MEMBER: Caller = Caller {
    uid: 62_011,
    gid: 62_020,
    groups: &[INSTALL_GROUP],
};

pub const ROOT: Caller = Caller {
    uid: 0,
    gid: 0,
    groups: &[0],
};

fn home_of(uid: u32) -> Option<PathBuf> {
    nix::unistd::User::from_uid(Uid::from_raw(uid))
        .ok()
        .flatten()
        .map(|user| user.dir)
}

/// The insecure-mode helper statically linked for musl, the only kind that runs setuid.
pub fn static_insecure_helper() -> PathBuf {
    let target = format!("{}-unknown-linux-musl", std::env::consts::ARCH);
    let target_dir = Path::new(MANIFEST_DIR).join("../target/setuid-e2e/insecure");
    let mut cargo = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned()));
    cargo
        .current_dir(MANIFEST_DIR)
        .args([
            "build",
            "--quiet",
            "-p",
            "hyper-suidhelper",
            "--bin",
            "hyper-suidhelper",
            "--features",
            "insecure_mode",
            "--target",
            &target,
            "--target-dir",
        ])
        .arg(&target_dir);
    for coverage_or_target in [
        "RUSTFLAGS",
        "CARGO_ENCODED_RUSTFLAGS",
        "RUSTC_WRAPPER",
        "RUSTC_WORKSPACE_WRAPPER",
        "LLVM_PROFILE_FILE",
        "CARGO_TARGET_DIR",
        "CARGO_BUILD_TARGET_DIR",
        "CARGO_LLVM_COV",
        "CARGO_LLVM_COV_TARGET_DIR",
    ] {
        cargo.env_remove(coverage_or_target);
    }
    let invoker = std::env::var("SUDO_UID")
        .ok()
        .zip(std::env::var("SUDO_GID").ok())
        .and_then(|(uid, gid)| Some((uid.parse::<u32>().ok()?, gid.parse::<u32>().ok()?)));
    if let Some((uid, gid)) = invoker {
        if let Some(home) = home_of(uid) {
            cargo.env("HOME", home);
        }
        cargo.uid(uid).gid(gid);
    }
    assert!(
        cargo.status().expect("spawning cargo").success(),
        "building the static insecure helper failed"
    );
    target_dir.join(&target).join("debug/hyper-suidhelper")
}

/// A tempdir every caller can traverse, holding a `root:<INSTALL_GROUP>` 4755 copy of the helper.
pub struct Install {
    pub dir: TempDir,
    pub bin: PathBuf,
}

impl Install {
    pub fn new() -> Self {
        let dir = TempDir::new().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        let bin = dir.path().join("hyper-suidhelper");
        fs::copy(static_insecure_helper(), &bin).unwrap();
        nix::unistd::chown(
            &bin,
            Some(Uid::from_raw(0)),
            Some(Gid::from_raw(INSTALL_GROUP)),
        )
        .unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o4755)).unwrap();
        Self { dir, bin }
    }

    pub fn path(&self) -> &Path {
        self.dir.path()
    }

    /// A world-readable, root-owned config naming `work_dir` and a cgroup that does not exist.
    pub fn config(&self, work_dir: &Path) -> PathBuf {
        let path = self.path().join("config.toml");
        fs::write(
            &path,
            format!(
                "work_dir = \"{}\"\n[jails]\ncgroup = \"hyper-e2e-does-not-exist\"\n",
                work_dir.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        path
    }
}

/// What one helper invocation left behind.
#[derive(Debug)]
pub struct Outcome {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    /// `stat -c '%n %F %a %u %g'` of every path the script listed, as seen inside the namespace.
    pub state: String,
}

/// Run `bin` with `request` as `caller` (via `setpriv`, so the setuid bit does the elevating),
/// inside a private mount namespace whose `/run` is an empty tmpfs on which `setup` (a shell
/// snippet, run as root) stages whatever it likes first. `observe` lists paths to `stat` inside
/// the namespace after the helper exits.
pub fn run_in_fresh_run(
    install: &Install,
    config: &Path,
    caller: Caller,
    setup: &str,
    request: &serde_json::Value,
    observe: &[&str],
) -> Outcome {
    let out = install.path().join(format!(
        "out-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir(&out).unwrap();
    let groups = caller
        .groups
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(",");
    let as_caller = if caller.uid == 0 {
        String::new()
    } else if groups.is_empty() {
        format!(
            "setpriv --reuid {} --regid {} --clear-groups",
            caller.uid, caller.gid
        )
    } else {
        format!(
            "setpriv --reuid {} --regid {} --groups {groups}",
            caller.uid, caller.gid
        )
    };
    let script = format!(
        r#"set -e
mount -t tmpfs -o mode=0755 hyper-e2e-run /run
{setup}
set +e
{as_caller} env -i HYPER_SETUIDHELPER_IS_INSECURE_MODE=1 HYPER_SETUIDHELPER_CONFIG_PATH="$2" "$1" "$3" >"$4/stdout" 2>"$4/stderr"
echo $? >"$4/rc"
for p in {observe}; do stat -c '%n %F %a %u %g' "$p" 2>/dev/null; done >"$4/state"
exit 0
"#,
        observe = observe
            .iter()
            .map(|p| format!("'{p}'"))
            .collect::<Vec<_>>()
            .join(" "),
    );
    let status = Command::new("unshare")
        .args(["--mount", "--propagation", "private", "--", "/bin/sh", "-c"])
        .arg(&script)
        .arg("sh")
        .arg(&install.bin)
        .arg(config)
        .arg(request.to_string())
        .arg(&out)
        .env_clear()
        .env("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
        .status()
        .unwrap();
    assert!(status.success(), "the namespace script itself failed");
    let read = |name: &str| fs::read_to_string(out.join(name)).unwrap_or_default();
    Outcome {
        code: read("rc").trim().parse().ok(),
        stdout: read("stdout"),
        stderr: read("stderr"),
        state: read("state"),
    }
}

/// Run `bin` with `request` as `caller` against the host's own `/run`.
pub fn run_as(
    install: &Install,
    config: &Path,
    caller: Caller,
    request: &serde_json::Value,
) -> Outcome {
    let Caller { uid, gid, groups } = caller;
    let mut cmd = Command::new(&install.bin);
    cmd.arg(request.to_string())
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", config);
    // SAFETY: the hook runs in the forked child before exec and makes only raw id syscalls.
    unsafe {
        cmd.pre_exec(move || {
            let groups: Vec<Gid> = groups.iter().copied().map(Gid::from_raw).collect();
            nix::unistd::setgroups(&groups)?;
            nix::unistd::setresgid(Gid::from_raw(gid), Gid::from_raw(gid), Gid::from_raw(gid))?;
            nix::unistd::setresuid(Uid::from_raw(uid), Uid::from_raw(uid), Uid::from_raw(uid))?;
            Ok(())
        })
    };
    let out = cmd.output().unwrap();
    Outcome {
        code: out.status.code(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        state: String::new(),
    }
}
