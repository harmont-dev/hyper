//! Hostile operands to the dm ops, driven through the helper binary against a
//! real dm-thin pool. The caller is in the helper's group but may name any
//! device, id or file it likes. Laws:
//!   * `thin_fork_delta` reads mappings only from the pool's own metadata
//!     device: a `meta` that is not that pool's metadata is refused, never
//!     dumped and copied from;
//!   * a `scratch_id` already provisioned in the pool is refused and the
//!     volume holding it keeps its id and its bytes;
//!   * a device the call did not create (a pre-existing `hyper-scratch-N` or
//!     `hyper-copy-N`) is never removed by its cleanup;
//!   * no caller-chosen path ever reaches the kernel: every path operand of
//!     every table the helper hands `dmsetup` is a loop device or a hyper dm
//!     device, whatever bytes the caller's file names hold.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use hyperrs_linux::dm::DevPath;
use proptest::prelude::*;
use proptest::strategy::ValueTree;
use proptest::test_runner::{Config as RunnerConfig, TestRunner};
use rstest::rstest;
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

mod support;
use support::{is_root, run, DmDevice, LoopDevice, MapperDevice};

const BLOCK_SECTORS: u64 = 128;
const BLOCK_BYTES: u64 = BLOCK_SECTORS * 512;
const BLOCKS: u64 = 32;
const SIZE: u64 = BLOCKS * BLOCK_BYTES;

fn first_existing(candidates: &[&str]) -> Option<PathBuf> {
    candidates.iter().map(PathBuf::from).find(|p| p.exists())
}

fn sparse(path: &Path, bytes: u64) {
    fs::File::create(path).unwrap().set_len(bytes).unwrap();
}

fn write_config(base: &Path, dmsetup: &Path, thin_dump: &Path) -> PathBuf {
    let config = base.join("config.toml");
    fs::write(
        &config,
        format!(
            "work_dir = \"{}\"\n[tools]\ndmsetup = \"{}\"\nthin_dump = \"{}\"\n",
            base.display(),
            dmsetup.display(),
            thin_dump.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o644)).unwrap();
    config
}

fn write_block(dev: &str, block: u64, fill: u8) {
    let mut f = fs::OpenOptions::new().write(true).open(dev).unwrap();
    f.seek(SeekFrom::Start(block * BLOCK_BYTES)).unwrap();
    f.write_all(&vec![fill; BLOCK_BYTES as usize]).unwrap();
    f.sync_all().unwrap();
}

fn read_all(dev: &str) -> Vec<u8> {
    let mut buf = Vec::new();
    fs::File::open(dev).unwrap().read_to_end(&mut buf).unwrap();
    buf
}

fn dm_names() -> Vec<String> {
    let out = Command::new("dmsetup").arg("ls").output().unwrap();
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter_map(|l| l.split_whitespace().next().map(str::to_string))
        .collect()
}

fn live_table(name: &str) -> Option<String> {
    let out = Command::new("dmsetup")
        .args(["table", name])
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

struct Pool {
    name: String,
    pool: DmDevice,
    meta: LoopDevice,
    _data: LoopDevice,
}

impl Pool {
    fn new(base: &Path, name: &str) -> Option<Self> {
        sparse(&base.join(format!("{name}-meta.img")), 8 << 20);
        sparse(&base.join(format!("{name}-data.img")), 64 << 20);
        let meta = LoopDevice::attach(&base.join(format!("{name}-meta.img")))?;
        let data = LoopDevice::attach(&base.join(format!("{name}-data.img")))?;
        let pool = DmDevice::create(
            name,
            &format!(
                "0 {} thin-pool {} {} {BLOCK_SECTORS} 0",
                (64u64 << 20) / 512,
                meta.path(),
                data.path()
            ),
        )?;
        Some(Self {
            name: name.to_string(),
            pool,
            meta,
            _data: data,
        })
    }

    fn thin(&self, name: &str, id: u32, origin: Option<&str>) -> DmDevice {
        assert!(self.pool.message(&format!("create_thin {id}")));
        DmDevice::create(
            name,
            &format!(
                "0 {} thin {} {id}{}",
                SIZE / 512,
                self.pool.path(),
                origin.map(|o| format!(" {o}")).unwrap_or_default()
            ),
        )
        .expect("thin volume")
    }
}

struct Live {
    a: Pool,
    origin: MapperDevice,
    config: PathBuf,
    base: PathBuf,
    tag: String,
    _dir: TempDir,
}

impl Live {
    fn new(tag: &str) -> Option<Self> {
        if !is_root() {
            return None;
        }
        let dmsetup = first_existing(&["/usr/sbin/dmsetup", "/sbin/dmsetup"])?;
        let thin_dump = first_existing(&["/usr/local/sbin/thin_dump", "/usr/sbin/thin_dump"])?;
        let dir = TempDir::new().unwrap();
        let base = fs::canonicalize(dir.path()).unwrap();
        let thin_dump_copy = base.join("thin_dump");
        fs::copy(fs::canonicalize(thin_dump).unwrap(), &thin_dump_copy).unwrap();
        fs::set_permissions(&thin_dump_copy, fs::Permissions::from_mode(0o755)).unwrap();
        let config = write_config(&base, &dmsetup, &thin_dump_copy);
        let tag = format!("hyper-e2e-dmh-{tag}-{}", std::process::id());
        let a = Pool::new(&base, &format!("{tag}-pool"))?;
        let origin_bytes: Vec<u8> = (0..SIZE).map(|i| (i % 239) as u8 | 0x80).collect();
        fs::write(base.join("origin.img"), origin_bytes).unwrap();
        let origin = MapperDevice::linear(&format!("{tag}-origin"), &base.join("origin.img"))?;
        Some(Self {
            a,
            origin,
            config,
            base,
            tag,
            _dir: dir,
        })
    }

    fn parent(&self, id: u32) -> DmDevice {
        self.a.thin(
            &format!("{}-parent-{id}", self.tag),
            id,
            Some(&self.origin.path()),
        )
    }

    fn fork(&self, parent: &DmDevice, scratch_id: u32, meta: &str) -> (bool, String, PathBuf) {
        let cow = self.base.join(format!("cow-{scratch_id}.img"));
        sparse(&cow, 8 << 20);
        let out = run(
            &self.config,
            json!({
                "op": "thin_fork_delta",
                "pool": self.a.name,
                "meta": meta,
                "parent": parent.path().trim_start_matches("/dev/mapper/"),
                "scratch_id": scratch_id,
                "origin": self.origin.path(),
                "cow": cow,
                "chunk_sectors": 8,
            }),
        )
        .get_output()
        .clone();
        (
            out.status.success(),
            String::from_utf8_lossy(&out.stderr).into_owned(),
            cow,
        )
    }

    fn replay(&self, cow: &Path) -> Vec<u8> {
        let lo = LoopDevice::attach(cow).expect("cow loop");
        let replay = DmDevice::create(
            &format!("{}-replay", self.tag),
            &format!(
                "0 {} snapshot {} {} P 8",
                SIZE / 512,
                self.origin.path(),
                lo.path()
            ),
        )
        .expect("cow replays");
        read_all(&replay.path())
    }
}

macro_rules! live {
    ($tag:expr) => {
        match Live::new($tag) {
            Some(live) => live,
            None => {
                eprintln!("SKIP: needs root, dmsetup and thin_dump");
                return;
            }
        }
    };
}

#[test]
fn fork_delta_refuses_a_meta_device_that_is_not_the_pools_metadata_as_root() {
    let live = live!("meta");
    const SCRATCH: u32 = 700;
    let parent = live.parent(1);
    write_block(&parent.path(), 2, 0x5a);
    let want = read_all(&parent.path());

    let b = Pool::new(&live.base, &format!("{}-other", live.tag)).expect("second pool");
    let decoy = b.thin(&format!("{}-decoy", live.tag), SCRATCH, None);
    write_block(&decoy.path(), 5, 0x33);
    drop(decoy);
    assert!(b.pool.message("reserve_metadata_snap"));

    let (ok, stderr, cow) = live.fork(&parent, SCRATCH, b.meta.path());
    let _ = b.pool.message("release_metadata_snap");
    let detail = if ok {
        format!(
            "the fork succeeded and its replay {} the parent",
            if live.replay(&cow) == want {
                "matches"
            } else {
                "DIFFERS FROM"
            }
        )
    } else {
        stderr
    };
    assert!(
        !ok,
        "meta {} belongs to another pool, yet: {detail}",
        b.meta.path()
    );
}

#[rstest]
#[case::a_sibling_volumes_id(2)]
#[case::the_parents_own_id(1)]
fn fork_delta_with_a_scratch_id_in_use_leaves_that_volume_untouched_as_root(#[case] scratch: u32) {
    let live = live!(&format!("busy{scratch}"));
    let parent = live.parent(1);
    let sibling = live.a.thin(&format!("{}-sibling", live.tag), 2, None);
    write_block(&parent.path(), 3, 0x11);
    write_block(&sibling.path(), 4, 0x22);
    let victim = if scratch == 1 { &parent } else { &sibling };
    let before = read_all(&victim.path());
    let table = live_table(victim.path().trim_start_matches("/dev/mapper/"));

    let (ok, stderr, _) = live.fork(&parent, scratch, live.a.meta.path());

    assert!(!ok, "a fork into a provisioned id {scratch} succeeded");
    assert!(
        stderr.contains("create_snap"),
        "refused for the wrong reason: {stderr}"
    );
    assert_eq!(
        live_table(victim.path().trim_start_matches("/dev/mapper/")),
        table
    );
    assert!(
        read_all(&victim.path()) == before,
        "id {scratch}'s bytes changed"
    );
    assert!(
        !live.a.pool.message(&format!("create_thin {scratch}")),
        "id {scratch} was freed out from under its volume"
    );
    assert!(
        live.a.pool.message("reserve_metadata_snap")
            && live.a.pool.message("release_metadata_snap"),
        "the metadata snapshot was left reserved"
    );
}

#[rstest]
#[case::scratch_name("hyper-scratch", 701)]
#[case::copy_target_name("hyper-copy", 702)]
fn fork_delta_never_removes_a_device_it_did_not_create_as_root(
    #[case] prefix: &str,
    #[case] scratch: u32,
) {
    let live = live!(&prefix[6..]);
    let parent = live.parent(1);
    write_block(&parent.path(), 0, 0x44);
    let squatter_name = format!("{prefix}-{scratch}");
    fs::write(live.base.join("squat.img"), vec![0x99; 1 << 20]).unwrap();
    let squatter = MapperDevice::linear(&squatter_name, &live.base.join("squat.img"))
        .expect("pre-existing device");
    let table = live_table(&squatter_name);

    let (ok, stderr, _) = live.fork(&parent, scratch, live.a.meta.path());

    assert!(!ok, "fork succeeded despite {squatter_name} existing");
    assert_eq!(
        live_table(&squatter_name),
        table,
        "{squatter_name} was removed or replaced; stderr: {stderr}"
    );
    assert!(read_all(&squatter.path()) == vec![0x99; 1 << 20]);
    let other = if prefix == "hyper-scratch" {
        format!("hyper-copy-{scratch}")
    } else {
        format!("hyper-scratch-{scratch}")
    };
    assert!(!dm_names().contains(&other), "{other} outlived the call");
    assert!(
        live.a.pool.message(&format!("create_thin {scratch}")),
        "scratch id {scratch} was not freed"
    );
    assert!(live.a.pool.message(&format!("delete {scratch}")));
}

fn kernel_operands(table: &str) -> Vec<String> {
    table
        .as_bytes()
        .split(|&b| matches!(b, b'\t' | b'\n' | 0x0b | 0x0c | b'\r' | b' ' | 0xa0))
        .filter(|t| t.starts_with(b"/"))
        .map(|t| t.escape_ascii().to_string())
        .collect()
}

fn is_kernel_safe_device(operand: &str) -> bool {
    let loop_dev = operand
        .strip_prefix("/dev/loop")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()));
    let hyper_dm = operand.strip_prefix("/dev/mapper/hyper-").is_some_and(|n| {
        n.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"#+-.:=@_".contains(&b))
    });
    loop_dev || hyper_dm
}

fn hostile_file_name() -> impl Strategy<Value = String> {
    let ch = prop_oneof![
        Just('\u{a0}'),
        Just('\u{e0}'),
        Just('\\'),
        Just('#'),
        Just(';'),
        Just('\''),
        Just('"'),
        Just('$'),
        Just('-'),
        any::<char>(),
    ]
    .prop_filter("strict component", |c| {
        !matches!(c, '/' | '\0' | ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r')
    });
    prop::collection::vec(ch, 1..12)
        .prop_map(|cs| format!("f{}", cs.into_iter().collect::<String>()))
}

fn recording_dmsetup(base: &Path) -> PathBuf {
    let path = base.join("dmsetup");
    fs::write(
        &path,
        format!(
            "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done >> '{}/argv'\nprintf '\\1' >> '{}/argv'\nexit 0\n",
            base.display(),
            base.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn recorded_tables(base: &Path) -> Vec<String> {
    let raw = fs::read(base.join("argv")).unwrap_or_default();
    raw.split(|&b| b == 1)
        .flat_map(|call| {
            let args: Vec<&[u8]> = call.split(|&b| b == 0).collect();
            args.windows(2)
                .filter(|w| w[0] == b"--table")
                .map(|w| String::from_utf8_lossy(w[1]).into_owned())
                .collect::<Vec<_>>()
        })
        .collect()
}

fn request(op: &str, files: &[PathBuf]) -> Value {
    match op {
        "img_activate" => json!({
            "op": "img_activate",
            "name": "hyper-hostile-img",
            "base": files[0],
            "deltas": files[1..],
            "chunk_sectors": 8,
        }),
        _ => json!({
            "op": "thin_pool_create",
            "name": "hyper-hostile-pool",
            "metadata": files[0],
            "data": files[1],
            "block_sectors": BLOCK_SECTORS,
            "low_water": 0,
        }),
    }
}

#[rstest]
#[case::img_activate("img_activate")]
#[case::thin_pool_create("thin_pool_create")]
fn no_caller_path_ever_reaches_the_kernel_as_root(#[case] op: &str) {
    if !is_root() {
        eprintln!("SKIP: needs root");
        return;
    }
    let mut runner = TestRunner::new(RunnerConfig {
        cases: 12,
        ..RunnerConfig::default()
    });
    let names = prop::collection::vec(hostile_file_name(), 2..4);
    for _ in 0..12 {
        let names = names.new_tree(&mut runner).unwrap().current();
        let dir = TempDir::new().unwrap();
        let base = fs::canonicalize(dir.path()).unwrap();
        let dmsetup = recording_dmsetup(&base);
        let config = write_config(&base, &dmsetup, &dmsetup);
        let files: Vec<PathBuf> = names
            .iter()
            .enumerate()
            .map(|(i, n)| {
                let p = base.join(std::ffi::OsStr::from_bytes(format!("{i}{n}").as_bytes()));
                sparse(&p, 1 << 20);
                p
            })
            .collect();
        let req = request(op, &files);
        let operands = if op == "img_activate" {
            &files[..]
        } else {
            &files[..2]
        };
        let operands_valid = operands
            .iter()
            .all(|f| DevPath::try_from(f.clone()).is_ok());

        let out = run(&config, req.clone()).get_output().clone();

        assert_eq!(
            out.status.success(),
            operands_valid,
            "{req}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let tables = recorded_tables(&base);
        assert_eq!(
            tables.is_empty(),
            !operands_valid,
            "{req}: tables {tables:?}"
        );
        for table in &tables {
            for operand in kernel_operands(table) {
                assert!(
                    is_kernel_safe_device(&operand),
                    "{req}: caller-derived operand {operand:?} reached the kernel in {table:?}"
                );
            }
        }
    }
}
