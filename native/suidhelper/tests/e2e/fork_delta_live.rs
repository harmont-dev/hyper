//! `thin_fork_delta` against a real dm-thin pool, driven through the helper
//! binary. The oracle is the parent itself: replaying the produced COW store
//! as a dm-snapshot over the origin must read back byte-for-byte as the parent.
//! Laws:
//!   * for ANY set of whole- and partial-block writes over a non-zero origin
//!     (including none at all), replay == parent;
//!   * nothing outlives a call: no `hyper-scratch-*`/`hyper-copy-*` device,
//!     the scratch thin id is free for reuse, the metadata snapshot is
//!     released, and the parent is still live and unchanged;
//!   * `written_chunks` is zero exactly when nothing diverged and never more
//!     than the number of diverged blocks (each block fits one copy chunk);
//!   * two forks of different parents of one pool racing each other both
//!     produce their own parent's exact divergence.
#![cfg(feature = "insecure_mode")]

use assert_fs::TempDir;
use pretty_assertions::assert_eq;
use proptest::prelude::*;
use proptest::strategy::ValueTree;
use proptest::test_runner::{Config as RunnerConfig, TestRunner};
use serde_json::json;
use std::collections::BTreeSet;
use std::fs;
use std::io::{Seek, SeekFrom, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

mod support;
use support::{is_root, run, stdout_json, DmDevice, LoopDevice, MapperDevice};

const BLOCK_SECTORS: u64 = 128;
const BLOCK_BYTES: u64 = BLOCK_SECTORS * 512;
const BLOCKS: u64 = 32;
const SIZE: u64 = BLOCKS * BLOCK_BYTES;
const SCRATCH_ID: u32 = 900;

fn system_bin(name: &str) -> Option<PathBuf> {
    let out = Command::new("sh")
        .args(["-c", &format!("command -v {name}")])
        .output()
        .ok()?;
    fs::canonicalize(String::from_utf8(out.stdout).ok()?.trim()).ok()
}

fn sparse(path: &Path, bytes: u64) {
    fs::File::create(path).unwrap().set_len(bytes).unwrap();
}

struct Live {
    origin: MapperDevice,
    pool: DmDevice,
    _data: LoopDevice,
    meta: LoopDevice,
    config: PathBuf,
    base: PathBuf,
    _dir: TempDir,
    tag: String,
}

impl Live {
    fn new(tag: &str) -> Option<Self> {
        let (dmsetup, thin_dump) = (system_bin("dmsetup")?, system_bin("thin_dump")?);
        let dir = TempDir::new().unwrap();
        let base = fs::canonicalize(dir.path()).unwrap();
        let thin_dump_copy = base.join("thin_dump");
        fs::copy(&thin_dump, &thin_dump_copy).unwrap();
        fs::set_permissions(&thin_dump_copy, fs::Permissions::from_mode(0o755)).unwrap();
        let config = base.join("config.toml");
        fs::write(
            &config,
            format!(
                "work_dir = \"{}\"\n[tools]\ndmsetup = \"{}\"\nthin_dump = \"{}\"\n",
                base.display(),
                dmsetup.display(),
                thin_dump_copy.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o644)).unwrap();

        sparse(&base.join("meta.img"), 8 << 20);
        sparse(&base.join("data.img"), 64 << 20);
        let origin_bytes: Vec<u8> = (0..SIZE).map(|i| (i % 241) as u8 | 0x80).collect();
        fs::write(base.join("origin.img"), origin_bytes).unwrap();
        let meta = LoopDevice::attach(&base.join("meta.img"))?;
        let data = LoopDevice::attach(&base.join("data.img"))?;
        let tag = format!("hyper-e2e-fdl-{tag}-{}", std::process::id());
        let pool = DmDevice::create(
            &format!("{tag}-pool"),
            &format!(
                "0 {} thin-pool {} {} {BLOCK_SECTORS} 0",
                (64u64 << 20) / 512,
                meta.path(),
                data.path()
            ),
        )?;
        let origin = MapperDevice::linear(&format!("{tag}-origin"), &base.join("origin.img"))?;
        Some(Self {
            origin,
            pool,
            _data: data,
            meta,
            config,
            base,
            _dir: dir,
            tag,
        })
    }

    fn pool_name(&self) -> String {
        format!("{}-pool", self.tag)
    }

    fn parent(&self, id: u32) -> DmDevice {
        assert!(self.pool.message(&format!("create_thin {id}")));
        DmDevice::create(
            &format!("{}-parent-{id}", self.tag),
            &format!(
                "0 {} thin {} {id} {}",
                SIZE / 512,
                self.pool.path(),
                self.origin.path()
            ),
        )
        .expect("parent thin")
    }

    fn fork(&self, parent: &DmDevice, scratch_id: u32, cow: &Path) -> assert_cmd::assert::Assert {
        sparse(cow, 8 << 20);
        run(
            &self.config,
            json!({
                "op": "thin_fork_delta",
                "pool": self.pool_name(),
                "meta": self.meta.path(),
                "parent": parent.path().trim_start_matches("/dev/mapper/"),
                "scratch_id": scratch_id,
                "origin": self.origin.path(),
                "cow": cow,
                "chunk_sectors": 8,
            }),
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
        .expect("the cow store replays as a snapshot");
        fs::read(replay.path()).unwrap()
    }

    fn assert_nothing_outlived(&self, scratch_id: u32) {
        let listed = Command::new("dmsetup").arg("ls").output().unwrap();
        let listed = String::from_utf8_lossy(&listed.stdout);
        for prefix in ["hyper-scratch-", "hyper-copy-"] {
            let leftover = format!("{prefix}{scratch_id}");
            assert!(
                !listed
                    .lines()
                    .any(|l| l.split_whitespace().next() == Some(&leftover)),
                "{leftover} outlived the call:\n{listed}"
            );
        }
        assert!(
            self.pool.message("reserve_metadata_snap"),
            "the metadata snapshot was left reserved"
        );
        assert!(self.pool.message("release_metadata_snap"));
        assert!(
            self.pool.message(&format!("create_thin {scratch_id}")),
            "scratch id {scratch_id} was not freed"
        );
        assert!(self.pool.message(&format!("delete {scratch_id}")));
    }
}

#[derive(Debug, Clone)]
enum Divergence {
    Block {
        block: u64,
        fill: u8,
    },
    Partial {
        block: u64,
        offset: u64,
        len: u64,
        fill: u8,
    },
}

impl Divergence {
    fn block(&self) -> u64 {
        match *self {
            Divergence::Block { block, .. } | Divergence::Partial { block, .. } => block,
        }
    }

    fn apply(&self, dev: &str) {
        let (at, len, fill) = match *self {
            Divergence::Block { block, fill } => (block * BLOCK_BYTES, BLOCK_BYTES, fill),
            Divergence::Partial {
                block,
                offset,
                len,
                fill,
            } => (block * BLOCK_BYTES + offset * 512, len * 512, fill),
        };
        let mut f = fs::OpenOptions::new().write(true).open(dev).unwrap();
        f.seek(SeekFrom::Start(at)).unwrap();
        f.write_all(&vec![fill; len as usize]).unwrap();
        f.sync_all().unwrap();
    }
}

fn writes() -> impl Strategy<Value = Vec<Divergence>> {
    let one = prop_oneof![
        (0..BLOCKS, any::<u8>()).prop_map(|(block, fill)| Divergence::Block { block, fill }),
        (0..BLOCKS, 0u64..BLOCK_SECTORS, any::<u8>()).prop_flat_map(|(block, offset, fill)| {
            (1..=BLOCK_SECTORS - offset).prop_map(move |len| Divergence::Partial {
                block,
                offset,
                len,
                fill,
            })
        }),
    ];
    prop::collection::vec(one, 0..10)
}

macro_rules! require {
    ($live:expr) => {
        match (is_root(), $live) {
            (true, Some(live)) => live,
            _ => {
                eprintln!("SKIP: needs root, dmsetup, thin_dump and dm-thin");
                return;
            }
        }
    };
}

#[test]
fn fork_delta_replays_any_divergence_exactly_and_leaves_nothing_behind_as_root() {
    let live = require!(Live::new("prop"));
    let mut runner = TestRunner::new(RunnerConfig {
        cases: 8,
        failure_persistence: None,
        ..RunnerConfig::default()
    });
    let mut cases: Vec<Vec<Divergence>> = vec![Vec::new()];
    for _ in 0..7 {
        cases.push(writes().new_tree(&mut runner).unwrap().current());
    }

    for (n, case) in cases.iter().enumerate() {
        let parent = live.parent(10 + n as u32);
        for w in case {
            w.apply(&parent.path());
        }
        let before = fs::read(parent.path()).unwrap();
        let cow = live.base.join(format!("cow-{n}.img"));

        let out = live.fork(&parent, SCRATCH_ID, &cow).success();

        let diverged: BTreeSet<u64> = case.iter().map(Divergence::block).collect();
        let written = stdout_json(&out)["written_chunks"].as_u64().unwrap();
        assert_eq!(written == 0, diverged.is_empty(), "{case:?}: {written}");
        assert!(written <= diverged.len() as u64, "{case:?}: {written}");
        assert!(
            live.replay(&cow) == before,
            "replay differs from the parent: {case:?}"
        );
        assert!(
            fs::read(parent.path()).unwrap() == before,
            "the fork changed the parent: {case:?}"
        );
        live.assert_nothing_outlived(SCRATCH_ID);
    }
}

#[test]
fn racing_forks_of_two_parents_each_get_their_own_divergence_as_root() {
    let live = require!(Live::new("race"));
    let (a, b) = (live.parent(20), live.parent(21));
    for block in [0, 7, BLOCKS - 1] {
        Divergence::Block { block, fill: 0x0a }.apply(&a.path());
    }
    for block in [3, 7, 19] {
        Divergence::Block { block, fill: 0x0b }.apply(&b.path());
    }
    let (want_a, want_b) = (fs::read(a.path()).unwrap(), fs::read(b.path()).unwrap());
    let (cow_a, cow_b) = (live.base.join("cow-a.img"), live.base.join("cow-b.img"));

    std::thread::scope(|s| {
        let ta = s.spawn(|| live.fork(&a, 901, &cow_a).try_success().is_ok());
        let tb = s.spawn(|| live.fork(&b, 902, &cow_b).try_success().is_ok());
        assert!(ta.join().unwrap(), "fork of a failed under contention");
        assert!(tb.join().unwrap(), "fork of b failed under contention");
    });

    assert!(live.replay(&cow_a) == want_a, "a's replay is not a");
    assert!(live.replay(&cow_b) == want_b, "b's replay is not b");
    live.assert_nothing_outlived(901);
    live.assert_nothing_outlived(902);
}
