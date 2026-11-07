#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use rstest::{fixture, rstest};
use serde_json::{json, Value};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

mod support;
use support::{is_root, run, stdout_json};

const MIB: usize = 1 << 20;

struct Work {
    _dir: TempDir,
    base: PathBuf,
    config: PathBuf,
}

impl Work {
    fn file(&self, name: &str, contents: &[u8]) -> String {
        let path = self.base.join(name);
        fs::write(&path, contents).unwrap();
        path.display().to_string()
    }

    fn fail_create(&self, name: &str) {
        fs::write(self.base.join(format!("fail-create-{name}")), b"").unwrap();
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(self.base.join("dmsetup.log"))
            .unwrap_or_default()
            .lines()
            .map(|line| {
                line.split(' ')
                    .map(|word| {
                        if word.starts_with("/dev/loop") {
                            "{loop}"
                        } else {
                            word
                        }
                    })
                    .collect::<Vec<_>>()
                    .join(" ")
            })
            .collect()
    }
}

#[fixture]
fn work() -> Work {
    let dir = TempDir::new().unwrap();
    let base = fs::canonicalize(dir.path()).unwrap();
    let dmsetup = base.join("dmsetup");
    fs::write(
        &dmsetup,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{b}/dmsetup.log'\n\
             [ \"$1\" = create ] && [ -e \"{b}/fail-create-$2\" ] && exit 1\nexit 0\n",
            b = base.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&dmsetup, fs::Permissions::from_mode(0o755)).unwrap();
    let config = base.join("config.toml");
    fs::write(
        &config,
        format!(
            "work_dir = \"{}\"\n[tools]\ndmsetup = \"{}\"\n",
            base.display(),
            dmsetup.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o644)).unwrap();
    Work {
        _dir: dir,
        base,
        config,
    }
}

fn activate(base: &str, deltas: &[String]) -> Value {
    json!({
        "op": "img_activate",
        "name": "hyper-img-x",
        "base": base,
        "deltas": deltas,
        "chunk_sectors": 8,
    })
}

#[rstest]
#[case::base_only(0, &["create hyper-img-x-0 --readonly --table 0 2048 linear {loop} 0"])]
#[case::one_delta(1, &["create hyper-img-x-1 --readonly --table 0 2048 snapshot {loop} {loop} P 8"])]
#[case::two_deltas(2, &[
    "create hyper-img-x-1 --readonly --table 0 2048 snapshot {loop} {loop} P 8",
    "create hyper-img-x-2 --readonly --table 0 2048 snapshot /dev/mapper/hyper-img-x-1 {loop} P 8",
])]
fn img_activate_stacks_a_snapshot_per_delta_sized_by_the_base_as_root(
    work: Work,
    #[case] deltas: usize,
    #[case] calls: &[&str],
) {
    if !is_root() {
        eprintln!("SKIP img_activate: needs root to attach loops");
        return;
    }
    let base = work.file("base.img", &vec![0; MIB]);
    let deltas: Vec<String> = (1..=deltas)
        .map(|i| work.file(&format!("d{i}.img"), &vec![0; MIB / 4]))
        .collect();

    let out = stdout_json(&run(&work.config, activate(&base, &deltas)).success());

    assert_eq!(work.calls(), calls);
    let top = calls.last().unwrap().split(' ').nth(1).unwrap();
    assert_eq!(out["device"], format!("/dev/mapper/{top}"));
    let names: Vec<String> = calls
        .iter()
        .map(|call| call.split(' ').nth(1).unwrap().to_string())
        .collect();
    assert_eq!(out["names"], json!(names));
}

#[rstest]
fn img_activate_removes_the_layers_it_built_when_one_fails_as_root(work: Work) {
    if !is_root() {
        eprintln!("SKIP img_activate rollback: needs root to attach loops");
        return;
    }
    let base = work.file("base.img", &vec![0; MIB]);
    let deltas: Vec<String> = (1..=3)
        .map(|i| work.file(&format!("d{i}.img"), &vec![0; MIB / 4]))
        .collect();
    work.fail_create("hyper-img-x-3");

    run(&work.config, activate(&base, &deltas)).code(2);

    let verbs: Vec<String> = work
        .calls()
        .iter()
        .map(|call| call.split(' ').take(3).collect::<Vec<_>>().join(" "))
        .collect();
    assert_eq!(
        verbs,
        [
            "create hyper-img-x-1 --readonly",
            "create hyper-img-x-2 --readonly",
            "create hyper-img-x-3 --readonly",
            "remove --retry hyper-img-x-2",
            "remove --retry hyper-img-x-1",
        ]
    );
}

#[rstest]
#[case::base_outside_the_work_dir("/etc/passwd", None)]
#[case::missing_base("{work}/absent.img", None)]
#[case::delta_outside_the_work_dir("{work}/base.img", Some("/etc/passwd"))]
#[case::symlinked_delta("{work}/base.img", Some("{work}/link.img"))]
#[case::directory_delta("{work}/base.img", Some("{work}"))]
fn img_activate_refuses_any_layer_before_building_one_as_root(
    work: Work,
    #[case] base: &str,
    #[case] delta: Option<&str>,
) {
    if !is_root() {
        eprintln!("SKIP img_activate refusal: needs root to own the config");
        return;
    }
    work.file("base.img", &vec![0; MIB]);
    let good = work.file("d1.img", &vec![0; MIB / 4]);
    std::os::unix::fs::symlink("/etc/passwd", work.base.join("link.img")).unwrap();
    let at_work = |p: &str| p.replace("{work}", &work.base.display().to_string());
    let deltas: Vec<String> = [Some(good), delta.map(at_work)]
        .into_iter()
        .flatten()
        .collect();

    run(&work.config, activate(&at_work(base), &deltas)).code(2);

    assert!(work.calls().is_empty(), "{:?}", work.calls());
}

#[rstest]
fn thin_pool_create_clears_a_stale_pool_and_zeroes_only_the_metadata_header_as_root(work: Work) {
    if !is_root() {
        eprintln!("SKIP thin_pool_create: needs root to attach loops");
        return;
    }
    let junk = vec![0xAB; 8192];
    let metadata = work.file("meta.img", &junk);
    let data = work.file("data.img", &vec![0; MIB]);

    let out = stdout_json(
        &run(
            &work.config,
            json!({
                "op": "thin_pool_create",
                "name": "hyper-pool",
                "metadata": metadata,
                "data": data,
                "block_sectors": 128,
                "low_water": 0,
            }),
        )
        .success(),
    );

    assert_eq!(
        work.calls(),
        [
            "remove --retry hyper-pool",
            "create hyper-pool --table 0 2048 thin-pool {loop} {loop} 128 0",
        ]
    );
    assert_eq!(out["result"], "created");
    assert!(out["loops"]["metadata"]
        .as_str()
        .unwrap()
        .starts_with("/dev/loop"));
    let wiped = fs::read(&metadata).unwrap();
    assert!(
        wiped[..4096].iter().all(|&b| b == 0),
        "header must be zeroed"
    );
    assert_eq!(
        wiped[4096..],
        junk[4096..],
        "only the header may be touched"
    );
}

#[rstest]
fn thin_pool_create_refuses_metadata_outside_the_work_dir_as_root(work: Work) {
    if !is_root() {
        eprintln!("SKIP thin_pool_create refusal: needs root to own the config");
        return;
    }
    let data = work.file("data.img", &vec![0; MIB]);

    run(
        &work.config,
        json!({
            "op": "thin_pool_create",
            "name": "hyper-pool",
            "metadata": "/etc/passwd",
            "data": data,
            "block_sectors": 128,
            "low_water": 0,
        }),
    )
    .code(2);

    assert!(work.calls().is_empty());
}
