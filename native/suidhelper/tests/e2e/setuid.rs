//! The privilege gate observed on real setuid-root installs, driven by callers that are not
//! root. Static builds are compiled on demand for the musl target (the only kind the helper
//! may be installed as); the dynamically linked test binary stands in for a mis-install.
//!
//! Laws:
//! - a dynamically linked build installed setuid refuses every request before parsing it;
//! - `version` answers any caller of a static setuid install;
//! - a caller outside the install group is refused every privileged op with `NotInGroup`
//!   before the config is read, while a primary or supplementary member gets past the gate;
//! - an install with group root refuses every privileged op to every non-root caller;
//! - the config is read as the caller, never as root: a root-only config is unreadable to a
//!   member's setuid invocation and readable to root's;
//! - a production build ignores the insecure-mode env seams entirely;
//! - neither the caller's `PATH` nor `LD_PRELOAD` reaches the tool the helper runs as root;
//! - the tool the helper runs as root starts with an empty environment;
//! - that tool is genuine root (real, effective and saved ids 0, groups `[0]`) and inherits no
//!   descriptor the caller passed in, the contract `RootCommandExt::spawn_as_root` states;
//! - a request nested to the argv length limit is refused, never a crash.

use assert_fs::TempDir;
use nix::unistd::{setgroups, setresgid, setresuid, Gid, Uid};
use pretty_assertions::assert_eq;
use rstest::rstest;
use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

mod support;
use support::{is_root, BIN};

const MANIFEST_DIR: &str = env!("CARGO_MANIFEST_DIR");
const DYNAMIC_REFUSAL: &str =
    "hyper-suidhelper: refusing to run setuid as a dynamically linked binary\n";
const INSTALL_GROUP: u32 = 61_001;
const MALFORMED_TOML: &str = "this is not = valid = toml ===";
const ABSENT_DM: &str = "hyper-setuid-e2e-absent";

#[derive(Clone, Copy)]
struct Caller {
    uid: u32,
    gid: u32,
    groups: &'static [u32],
}

const MEMBER: Caller = Caller {
    uid: 61_010,
    gid: INSTALL_GROUP,
    groups: &[],
};
const SUPPLEMENTARY_MEMBER: Caller = Caller {
    uid: 61_011,
    gid: 61_020,
    groups: &[61_021, INSTALL_GROUP],
};
const OUTSIDER: Caller = Caller {
    uid: 61_012,
    gid: 61_022,
    groups: &[61_023],
};
const ROOT_GROUP_OUTSIDER: Caller = Caller {
    uid: 61_013,
    gid: 0,
    groups: &[0],
};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Build {
    Production,
    Insecure,
}

fn has_interpreter(elf: &[u8]) -> bool {
    const PT_INTERP: u32 = 3;
    let u16_at = |at: usize| usize::from(u16::from_le_bytes([elf[at], elf[at + 1]]));
    let phoff = usize::try_from(u64::from_le_bytes(elf[0x20..0x28].try_into().unwrap())).unwrap();
    let (phentsize, phnum) = (u16_at(0x36), u16_at(0x38));
    (0..phnum).any(|idx| {
        let at = phoff + idx * phentsize;
        u32::from_le_bytes(elf[at..at + 4].try_into().unwrap()) == PT_INTERP
    })
}

fn home_of(uid: u32) -> Option<PathBuf> {
    nix::unistd::User::from_uid(Uid::from_raw(uid))
        .ok()
        .flatten()
        .map(|user| user.dir)
}

fn static_helper(build: Build) -> PathBuf {
    let target = format!("{}-unknown-linux-musl", std::env::consts::ARCH);
    let variant = match build {
        Build::Production => "production",
        Build::Insecure => "insecure",
    };
    let target_dir = Path::new(MANIFEST_DIR)
        .join("../target/setuid-e2e")
        .join(variant);
    let mut cargo = Command::new(std::env::var("CARGO").unwrap_or_else(|_| "cargo".to_owned()));
    cargo.current_dir(MANIFEST_DIR).args([
        "build",
        "--quiet",
        "-p",
        "hyper-suidhelper",
        "--bin",
        "hyper-suidhelper",
        "--target",
        &target,
        "--target-dir",
    ]);
    cargo.arg(&target_dir);
    if build == Build::Insecure {
        cargo.args(["--features", "insecure_mode"]);
    }
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
    let status = cargo.status().expect("spawning cargo");
    assert!(
        status.success(),
        "building the {variant} static helper failed"
    );
    let bin = target_dir.join(&target).join("debug/hyper-suidhelper");
    assert!(
        !has_interpreter(&fs::read(&bin).unwrap()),
        "{} is not static",
        bin.display()
    );
    bin
}

struct Install {
    dir: TempDir,
    bin: PathBuf,
}

impl Install {
    fn setuid(source: &Path, group: u32) -> Self {
        let dir = TempDir::new().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o755)).unwrap();
        let bin = dir.path().join("hyper-suidhelper");
        fs::copy(source, &bin).unwrap();
        nix::unistd::chown(&bin, Some(Uid::from_raw(0)), Some(Gid::from_raw(group))).unwrap();
        fs::set_permissions(&bin, fs::Permissions::from_mode(0o4755)).unwrap();
        Self { dir, bin }
    }

    fn config(&self, body: &str, mode: u32) -> PathBuf {
        let path = self.dir.path().join(format!("config-{mode:o}.toml"));
        fs::write(&path, body).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
        path
    }

    fn run(&self, caller: Caller, request: &Value, env: &[(&str, &Path)]) -> Output {
        let mut cmd = Command::new(&self.bin);
        cmd.arg(request.to_string()).env_clear();
        for (key, value) in env {
            cmd.env(key, value);
        }
        let Caller { uid, gid, groups } = caller;
        // SAFETY: the hook runs in the forked child before exec and makes only raw id syscalls.
        unsafe {
            cmd.pre_exec(move || {
                let groups: Vec<Gid> = groups.iter().copied().map(Gid::from_raw).collect();
                setgroups(&groups)?;
                setresgid(Gid::from_raw(gid), Gid::from_raw(gid), Gid::from_raw(gid))?;
                setresuid(Uid::from_raw(uid), Uid::from_raw(uid), Uid::from_raw(uid))?;
                Ok(())
            })
        };
        cmd.output().unwrap()
    }
}

fn stderr(out: &Output) -> String {
    String::from_utf8_lossy(&out.stderr).into_owned()
}

fn privileged_requests() -> Vec<Value> {
    let fixture: serde_json::Map<String, Value> =
        serde_json::from_str(include_str!("../fixtures/requests.json")).unwrap();
    fixture
        .into_iter()
        .map(|(_, request)| request)
        .filter(|request| request["op"] != "version")
        .collect()
}

fn insecure_env(config: &Path) -> [(&'static str, &Path); 2] {
    [
        ("HYPER_SETUIDHELPER_IS_INSECURE_MODE", Path::new("1")),
        ("HYPER_SETUIDHELPER_CONFIG_PATH", config),
    ]
}

#[rstest]
#[case::version(json!({"op": "version"}))]
#[case::privileged(json!({"op": "vm_teardown", "id": "v1"}))]
#[case::malformed(json!("not a request"))]
fn a_dynamically_linked_setuid_install_refuses_every_request_as_root(#[case] request: Value) {
    if !is_root() {
        eprintln!("SKIP dynamic setuid install: needs root to install setuid");
        return;
    }
    assert!(
        has_interpreter(&fs::read(BIN).unwrap()),
        "the test binary must be dynamic"
    );
    let install = Install::setuid(Path::new(BIN), INSTALL_GROUP);

    let out = install.run(MEMBER, &request, &[]);

    assert_eq!(
        (out.status.code(), stderr(&out), out.stdout.len()),
        (Some(1), DYNAMIC_REFUSAL.to_owned(), 0)
    );
}

#[rstest]
#[case::member(MEMBER)]
#[case::outsider(OUTSIDER)]
#[case::root_group_outsider(ROOT_GROUP_OUTSIDER)]
fn version_answers_any_caller_of_a_static_setuid_install_as_root(#[case] caller: Caller) {
    if !is_root() {
        eprintln!("SKIP static setuid version: needs root to install setuid");
        return;
    }
    let install = Install::setuid(&static_helper(Build::Production), INSTALL_GROUP);

    let out = install.run(caller, &json!({"op": "version"}), &[]);

    assert!(out.status.success(), "{}", stderr(&out));
    let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(reply["version"], env!("CARGO_PKG_VERSION"));
}

#[rstest]
fn an_outsider_is_refused_every_privileged_op_before_the_config_is_read_as_root() {
    if !is_root() {
        eprintln!("SKIP outsider gate: needs root to install setuid");
        return;
    }
    let install = Install::setuid(&static_helper(Build::Insecure), INSTALL_GROUP);
    let config = install.config(MALFORMED_TOML, 0o644);
    let refusal = format!(
        "uid {} is not in the helper's group {INSTALL_GROUP}",
        OUTSIDER.uid
    );

    for request in privileged_requests() {
        let outsider = install.run(OUTSIDER, &request, &insecure_env(&config));
        let member = install.run(MEMBER, &request, &insecure_env(&config));
        let supplementary = install.run(SUPPLEMENTARY_MEMBER, &request, &insecure_env(&config));

        assert_eq!(outsider.status.code(), Some(2), "{request}");
        assert!(
            stderr(&outsider).contains(&refusal),
            "{request}: {}",
            stderr(&outsider)
        );
        assert!(!stderr(&outsider).contains("not valid TOML"), "{request}");
        for passed in [member, supplementary] {
            assert!(
                stderr(&passed).contains("not valid TOML"),
                "{request}: a member must reach the config: {}",
                stderr(&passed)
            );
        }
    }
}

#[rstest]
#[case::member_of_nothing(OUTSIDER)]
#[case::primary_group_root(ROOT_GROUP_OUTSIDER)]
fn a_root_group_install_refuses_every_privileged_op_to_non_root_callers_as_root(
    #[case] caller: Caller,
) {
    if !is_root() {
        eprintln!("SKIP root-group install: needs root to install setuid");
        return;
    }
    let install = Install::setuid(&static_helper(Build::Insecure), 0);
    let config = install.config(MALFORMED_TOML, 0o644);

    for request in privileged_requests() {
        let out = install.run(caller, &request, &insecure_env(&config));

        assert_eq!(out.status.code(), Some(2), "{request}");
        assert!(
            stderr(&out).contains("installed with group root, so only root may run it"),
            "{request}: {}",
            stderr(&out)
        );
    }
}

#[rstest]
#[case::member_cannot_read_a_root_only_config(MEMBER, 0o600, "open failed: EACCES")]
#[case::member_reads_a_world_readable_config(MEMBER, 0o644, "not valid TOML")]
#[case::root_reads_a_root_only_config(
    Caller { uid: 0, gid: 0, groups: &[0] }, 0o600, "not valid TOML")]
fn the_config_is_read_as_the_caller_never_as_root_as_root(
    #[case] caller: Caller,
    #[case] mode: u32,
    #[case] outcome: &str,
) {
    if !is_root() {
        eprintln!("SKIP config read identity: needs root to install setuid");
        return;
    }
    let install = Install::setuid(&static_helper(Build::Insecure), INSTALL_GROUP);
    let config = install.config(MALFORMED_TOML, mode);

    let out = install.run(
        caller,
        &json!({"op": "vm_teardown", "id": "v1"}),
        &insecure_env(&config),
    );

    assert_eq!(out.status.code(), Some(2));
    assert!(stderr(&out).contains(outcome), "{}", stderr(&out));
}

#[rstest]
#[case::production(Build::Production, false)]
#[case::insecure(Build::Insecure, true)]
fn only_an_insecure_build_honours_the_insecure_seams_as_root(
    #[case] build: Build,
    #[case] honoured: bool,
) {
    if !is_root() {
        eprintln!("SKIP insecure seams: needs root to install setuid");
        return;
    }
    let install = Install::setuid(&static_helper(build), INSTALL_GROUP);
    let config = install.config(MALFORMED_TOML, 0o644);

    let out = install.run(
        MEMBER,
        &json!({"op": "dm_remove", "name": ABSENT_DM, "retry": false}),
        &insecure_env(&config),
    );

    let stderr = stderr(&out);
    assert_eq!(out.status.code(), Some(2), "{stderr}");
    assert_eq!(
        (
            stderr.contains("INSECURE TEST MODE"),
            stderr.contains("not valid TOML")
        ),
        (honoured, honoured),
        "{stderr}"
    );
}

fn compile_preload(dir: &Path, marker: &Path) -> PathBuf {
    let source = dir.join("preload.c");
    let library = dir.join("preload.so");
    fs::write(
        &source,
        format!(
            "#include <stdio.h>\n#include <unistd.h>\n\
             __attribute__((constructor)) static void hijack(void) {{\n\
             FILE *f = fopen(\"{}\", \"a\"); if (f) {{ fprintf(f, \"preload uid=%d euid=%d\\n\", \
             getuid(), geteuid()); fclose(f); }} }}\n",
            marker.display()
        ),
    )
    .unwrap();
    let status = Command::new("cc")
        .args(["-shared", "-fPIC", "-o"])
        .arg(&library)
        .arg(&source)
        .status()
        .expect("a C compiler builds the preload library");
    assert!(status.success());
    fs::set_permissions(&library, fs::Permissions::from_mode(0o755)).unwrap();
    library
}

fn plant_path_tool(dir: &Path, marker: &Path) -> PathBuf {
    let bin = dir.join("path-bin");
    fs::create_dir(&bin).unwrap();
    fs::set_permissions(&bin, fs::Permissions::from_mode(0o755)).unwrap();
    let tool = bin.join("dmsetup");
    fs::write(
        &tool,
        format!(
            "#!/bin/sh\necho \"path dmsetup $(id -u)\" >> '{}'\n",
            marker.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&tool, fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

#[rstest]
fn the_callers_path_and_preload_never_reach_the_root_tool_as_root() {
    if !is_root() {
        eprintln!("SKIP env poisoning: needs root to install setuid");
        return;
    }
    let install = Install::setuid(&static_helper(Build::Production), INSTALL_GROUP);
    let scratch = TempDir::new().unwrap();
    fs::set_permissions(scratch.path(), fs::Permissions::from_mode(0o777)).unwrap();
    let marker = scratch.path().join("hijacked");
    let preload = compile_preload(scratch.path(), &marker);
    let path = plant_path_tool(scratch.path(), &marker);

    let control = Command::new("/bin/true")
        .env("LD_PRELOAD", &preload)
        .status()
        .unwrap();
    assert!(
        control.success() && marker.exists(),
        "the preload library must work"
    );
    fs::remove_file(&marker).unwrap();

    let out = install.run(
        MEMBER,
        &json!({"op": "dm_remove", "name": ABSENT_DM, "retry": false}),
        &[
            ("PATH", &path),
            ("LD_PRELOAD", &preload),
            ("LD_LIBRARY_PATH", scratch.path()),
        ],
    );

    assert!(
        stderr(&out).contains(ABSENT_DM),
        "the helper must reach its dmsetup: {}",
        stderr(&out)
    );
    assert!(
        !marker.exists(),
        "caller env reached a tool: {}",
        fs::read_to_string(&marker).unwrap_or_default()
    );
}

const RECORDER_C: &str = r#"
#define _GNU_SOURCE
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
extern char **environ;
int main(void) {
    char links[64][512];
    int fds[64], nfds = 0;
    DIR *dir = opendir("/proc/self/fd");
    struct dirent *entry;
    while (dir && (entry = readdir(dir)) && nfds < 64) {
        if (entry->d_name[0] == '.' || atoi(entry->d_name) == dirfd(dir)) continue;
        char path[64];
        snprintf(path, sizeof path, "/proc/self/fd/%s", entry->d_name);
        ssize_t len = readlink(path, links[nfds], sizeof links[nfds] - 1);
        links[nfds][len < 0 ? 0 : len] = 0;
        fds[nfds++] = atoi(entry->d_name);
    }
    if (dir) closedir(dir);
    uid_t ru, eu, su;
    gid_t rg, eg, sg, groups[64];
    getresuid(&ru, &eu, &su);
    getresgid(&rg, &eg, &sg);
    int ngroups = getgroups(64, groups), nenv = 0;
    while (environ[nenv]) nenv++;
    FILE *out = fopen(RECORD, "w");
    fprintf(out, "{\"uids\":[%u,%u,%u],\"gids\":[%u,%u,%u],\"groups\":[", ru, eu, su, rg, eg, sg);
    for (int i = 0; i < ngroups; i++) fprintf(out, "%s%u", i ? "," : "", groups[i]);
    fprintf(out, "],\"env\":%d,\"fds\":{", nenv);
    for (int i = 0; i < nfds; i++) fprintf(out, "%s\"%d\":\"%s\"", i ? "," : "", fds[i], links[i]);
    fprintf(out, "}}");
    fclose(out);
    return 0;
}
"#;

const CALLER_FD: i32 = 37;

fn record_the_root_tool() -> Value {
    let install = Install::setuid(&static_helper(Build::Insecure), INSTALL_GROUP);
    let record = install.dir.path().join("record.json");
    let source = install.dir.path().join("recorder.c");
    let tool = install.dir.path().join("dmsetup");
    fs::write(&source, RECORDER_C).unwrap();
    let built = Command::new("cc")
        .arg(format!("-DRECORD=\"{}\"", record.display()))
        .arg("-o")
        .arg(&tool)
        .arg(&source)
        .status()
        .expect("a C compiler builds the recording tool");
    assert!(built.success());
    fs::set_permissions(&tool, fs::Permissions::from_mode(0o755)).unwrap();
    fs::set_permissions(install.dir.path(), fs::Permissions::from_mode(0o777)).unwrap();
    let config = install.config(
        &format!(
            "work_dir = \"/srv/hyper\"\n[tools]\ndmsetup = \"{}\"\n",
            tool.display()
        ),
        0o644,
    );
    let secret = install.dir.path().join("caller-secret");
    fs::write(&secret, "caller").unwrap();
    let passed = fs::File::open(&secret).unwrap();

    let mut cmd = Command::new(&install.bin);
    cmd.arg(json!({"op": "dm_remove", "name": ABSENT_DM, "retry": false}).to_string())
        .env_clear()
        .env("HYPER_SETUIDHELPER_IS_INSECURE_MODE", "1")
        .env("HYPER_SETUIDHELPER_CONFIG_PATH", &config)
        .env("LD_PRELOAD", "/nonexistent/preload.so")
        .env("PATH", install.dir.path());
    let Caller { uid, gid, groups } = SUPPLEMENTARY_MEMBER;
    let raw = std::os::unix::io::AsRawFd::as_raw_fd(&passed);
    // SAFETY: the hook runs in the forked child before exec and makes only raw fd/id syscalls.
    unsafe {
        cmd.pre_exec(move || {
            if nix::libc::dup2(raw, CALLER_FD) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let groups: Vec<Gid> = groups.iter().copied().map(Gid::from_raw).collect();
            setgroups(&groups)?;
            setresgid(Gid::from_raw(gid), Gid::from_raw(gid), Gid::from_raw(gid))?;
            setresuid(Uid::from_raw(uid), Uid::from_raw(uid), Uid::from_raw(uid))?;
            Ok(())
        })
    };
    let out = cmd.output().unwrap();
    assert!(out.status.success(), "{}", stderr(&out));
    let recorded: Value = serde_json::from_str(&fs::read_to_string(&record).unwrap()).unwrap();
    let leaked_caller_fd = recorded["fds"]
        .as_object()
        .unwrap()
        .values()
        .any(|target| target == secret.to_str().unwrap());
    json!({
        "uids": recorded["uids"],
        "gids": recorded["gids"],
        "groups": recorded["groups"],
        "env": recorded["env"],
        "caller_fd_inherited": leaked_caller_fd,
    })
}

#[rstest]
fn the_root_tool_starts_with_an_empty_environment_as_root() {
    if !is_root() {
        eprintln!("SKIP root tool env: needs root to install setuid");
        return;
    }
    assert_eq!(record_the_root_tool()["env"], json!(0));
}

#[rstest]
fn the_root_tool_is_genuine_root_and_inherits_no_caller_fd_as_root() {
    if !is_root() {
        eprintln!("SKIP root tool identity: needs root to install setuid");
        return;
    }
    let recorded = record_the_root_tool();

    assert_eq!(
        json!({
            "uids": recorded["uids"],
            "gids": recorded["gids"],
            "groups": recorded["groups"],
            "caller_fd_inherited": recorded["caller_fd_inherited"],
        }),
        json!({
            "uids": [0, 0, 0],
            "gids": [0, 0, 0],
            "groups": [0],
            "caller_fd_inherited": false,
        })
    );
}

#[rstest]
#[case::arrays("[", "]")]
#[case::objects("{\"op\":", "}")]
fn a_request_nested_to_the_argv_limit_is_refused_not_crashed(
    #[case] open: &str,
    #[case] close: &str,
) {
    let depth = (128 * 1024 - 64) / (open.len() + close.len());
    let request = format!("{}0{}", open.repeat(depth), close.repeat(depth));

    let out = Command::new(BIN)
        .arg(&request)
        .env_clear()
        .output()
        .unwrap();

    assert_eq!(out.status.signal(), None, "{}", stderr(&out));
    assert_eq!(out.status.code(), Some(2));
    assert!(
        stderr(&out).starts_with("invalid request:"),
        "{}",
        stderr(&out)
    );
}
