//! `Dmsetup`, `ThinDump` and `LoopControl` against both recording fakes and
//! the real kernel. Root only: `RootSafeBin` demands a root-owned binary, and
//! the live cases create loop and dm devices. Laws:
//!   * argv is exactly the documented verb shape, the rendered table and every
//!     message travel as ONE argv element, and no caller environment leaks;
//!   * a non-zero exit is `RunError::Failed` carrying the trimmed stderr;
//!   * `thin_dump` reads the metadata device through the inherited fd it is
//!     given, and a mapping total that overflows is refused, never a panic;
//!   * a loop device is read-only exactly when attached `ReadOnly`, and
//!     auto-detaches once nothing holds it (no leak);
//!   * a live table is sized, numbered and protected as requested;
//!   * on a real pool: an id is never provisioned twice, a snapshot is the
//!     origin frozen at snapshot time, and the dumped mappings of a thin are
//!     exactly the blocks written to it (oracle: the set of written blocks);
//!   * the metadata snapshot can be held only once at a time.

#![feature(adt_const_params, unsized_const_params)]
#![allow(incomplete_features)]

use assert_fs::TempDir;
use hyperrs_fs::dev::DeviceNumber;
use hyperrs_fs::file::{Any, IsBlockDevice, IsRegularFile, OpenFlags, SafeFile};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use hyperrs_linux::dm::thin_dump::{BlockRange, MappingsError, ThinDump};
use hyperrs_linux::dm::{
    DevPath, Device, DmName, DmTable, Dmsetup, LinearTable, Origin, RemoveMode, RunError, ThinId,
    ThinPoolTable, ThinTable,
};
use hyperrs_linux::loopdev::{LoopControl, LoopDevice};
use hyperrs_linux::Access;
use hyperrs_process::binary::RootSafeBin;
use pretty_assertions::assert_eq;
use proptest::prelude::*;
use proptest::strategy::ValueTree;
use std::collections::BTreeSet;
use std::fs;
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

const DMSETUP: &str = "/usr/sbin/dmsetup";
const THIN_DUMP: &str = "/usr/local/sbin/thin_dump";
const BLOCK_SECTORS: u64 = 128;
const BLOCK_BYTES: u64 = BLOCK_SECTORS * 512;

fn is_root() -> bool {
    nix::unistd::geteuid().is_root()
}

macro_rules! require_root {
    () => {
        if !is_root() {
            eprintln!("SKIP: needs root");
            return;
        }
    };
}

fn real(dir: &TempDir) -> PathBuf {
    fs::canonicalize(dir.path()).unwrap()
}

fn install(dir: &Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn recorded_argv(path: &Path) -> Vec<String> {
    let raw = fs::read(path).unwrap();
    raw.split(|&b| b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8(s.to_vec()).unwrap())
        .collect()
}

struct FakeDmsetup {
    _dir: TempDir,
    base: PathBuf,
    dmsetup: Dmsetup,
}

impl FakeDmsetup {
    fn new(extra: &str) -> Self {
        let dir = TempDir::new().unwrap();
        let base = real(&dir);
        let bin = install(
            &base,
            "dmsetup",
            &format!(
                "printf '%s\\0' \"$@\" > '{b}/argv'\n\
                 env > '{b}/env'\n\
                 {extra}\n\
                 exit 0\n",
                b = base.display()
            ),
        );
        Self {
            dmsetup: Dmsetup::new(RootSafeBin::open(&bin).unwrap()),
            _dir: dir,
            base,
        }
    }

    fn argv(&self) -> Vec<String> {
        recorded_argv(&self.base.join("argv"))
    }

    fn env(&self) -> String {
        fs::read_to_string(self.base.join("env")).unwrap()
    }
}

fn name(s: &str) -> DmName {
    s.parse().unwrap()
}

fn dev_path(p: impl AsRef<Path>) -> DevPath {
    p.as_ref().to_path_buf().try_into().unwrap()
}

fn table() -> impl Strategy<Value = DmTable> {
    let origin = prop_oneof![
        "hyper-[a-z0-9]{1,6}".prop_map(|s| Origin::Device(name(&s))),
        "/srv/[a-z0-9_-][a-z0-9._-]{0,7}".prop_map(|s| Origin::Path(dev_path(s))),
    ];
    prop_oneof![
        (any::<u64>(), origin.clone())
            .prop_map(|(sectors, origin)| DmTable::Linear(LinearTable { sectors, origin })),
        (any::<u64>(), 0u32..=ThinId::MAX, prop::option::of(origin)).prop_map(
            |(sectors, id, origin)| DmTable::Thin(ThinTable {
                sectors,
                pool: name("hyper-pool"),
                id: ThinId::new(id).unwrap(),
                origin,
            })
        ),
    ]
}

#[test]
fn create_passes_the_whole_table_as_one_argument_and_no_environment_as_root() {
    require_root!();
    std::env::set_var("HYPER_LEAK_PROBE", "leaked");
    let fake = FakeDmsetup::new("");
    let mut runner = proptest::test_runner::TestRunner::new(ProptestConfig::with_cases(24));
    runner
        .run(
            &(table(), "hyper-[a-z0-9]{1,8}", any::<bool>()),
            |(t, n, ro)| {
                let access = if ro {
                    Access::ReadOnly
                } else {
                    Access::ReadWrite
                };
                let dev = fake.dmsetup.create(&name(&n), &t, access).unwrap();
                let mut expected = vec!["create".to_string(), n.clone()];
                if ro {
                    expected.push("--readonly".into());
                }
                expected.extend(["--table".into(), t.to_string()]);
                prop_assert_eq!(fake.argv(), expected);
                prop_assert_eq!(dev.name().to_string(), n);
                prop_assert!(!fake.env().contains("HYPER_LEAK_PROBE"), "{}", fake.env());
                Ok(())
            },
        )
        .unwrap();
}

type Verb = fn(&Device) -> Result<(), RunError>;

#[test]
fn every_device_verb_names_exactly_the_device_as_root() {
    require_root!();
    let fake = FakeDmsetup::new("");
    let dev = fake.dmsetup.device(&name("hyper-vol"));

    let verbs: [(Verb, &[&str]); 4] = [
        (|d| d.suspend(), &["suspend", "hyper-vol"]),
        (|d| d.resume(), &["resume", "hyper-vol"]),
        (
            |d| d.clone().remove(RemoveMode::Once),
            &["remove", "hyper-vol"],
        ),
        (
            |d| d.clone().remove(RemoveMode::Retry),
            &["remove", "--retry", "hyper-vol"],
        ),
    ];
    for (verb, argv) in verbs {
        verb(&dev).unwrap();
        assert_eq!(fake.argv(), argv);
    }
}

#[test]
fn a_failing_dmsetup_is_an_error_carrying_its_trimmed_stderr_as_root() {
    require_root!();
    let fake = FakeDmsetup::new(
        "printf 'looks fine\\n'\nprintf '\\n  device-mapper: reload ioctl failed  \\n\\n' >&2\nexit 3",
    );

    let err = fake
        .dmsetup
        .device(&name("hyper-vol"))
        .suspend()
        .unwrap_err();

    match err {
        RunError::Failed(msg) => assert_eq!(msg, "device-mapper: reload ioctl failed"),
        other => panic!("expected Failed, got {other:?}"),
    }
}

#[test]
fn device_number_accepts_only_a_major_minor_pair_as_root() {
    require_root!();
    for (out, expected) in [
        ("253:7", Some((253, 7))),
        ("  253:7  ", Some((253, 7))),
        ("", None),
        ("253", None),
        ("253:7:1", None),
        ("x:7", None),
        ("253:-1", None),
    ] {
        let fake = FakeDmsetup::new(&format!("printf '%s\\n' '{out}'"));
        let got = fake.dmsetup.device(&name("hyper-vol")).number();
        assert_eq!(
            got.ok().map(|n| (n.major(), n.minor())),
            expected,
            "dmsetup info printed {out:?}"
        );
    }
}

struct Loop {
    device: Option<LoopDevice>,
    path: PathBuf,
}

impl Loop {
    fn attach(file: &Path, access: Access) -> Self {
        let control = LoopControl::open().unwrap();
        let path: SafePathBuf<IsAbsolute, StrictComponents> = dev_path(file).into();
        let backing = SafeFile::<IsRegularFile, Any, Any>::open(&path, OpenFlags::PATH).unwrap();
        let device = control
            .attach(&backing, access, Duration::from_secs(2))
            .unwrap();
        let path = device.path().as_path().to_path_buf();
        Self {
            device: Some(device),
            path,
        }
    }

    fn sysfs(&self, attr: &str) -> Option<String> {
        let n = self.path.file_name()?.to_str()?;
        fs::read_to_string(format!("/sys/block/{n}/{attr}"))
            .ok()
            .map(|s| s.trim().to_string())
    }

    fn release(&mut self) {
        self.device.take();
    }

    fn detached_within(&self, limit: Duration) -> bool {
        let deadline = Instant::now() + limit;
        while Instant::now() < deadline {
            if self.sysfs("loop/backing_file").is_none() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        false
    }
}

fn write_lands(dev: &Path, backing: &Path, fill: u8) -> bool {
    let attempt = fs::OpenOptions::new()
        .write(true)
        .open(dev)
        .and_then(|mut f| {
            f.write_all(&[fill; 512])?;
            f.sync_all()
        });
    let landed = fs::read(backing).unwrap()[..512] == [fill; 512];
    assert_eq!(attempt.is_ok(), landed, "write reported {attempt:?}");
    landed
}

fn sparse(path: &Path, bytes: u64) {
    fs::File::create(path).unwrap().set_len(bytes).unwrap();
}

#[test]
fn a_loop_is_read_only_exactly_when_asked_and_never_outlives_its_holder_as_root() {
    require_root!();
    let dir = TempDir::new().unwrap();
    let file = real(&dir).join("disk.img");
    sparse(&file, 1 << 20);

    for (access, ro) in [(Access::ReadOnly, "1"), (Access::ReadWrite, "0")] {
        let mut lo = Loop::attach(&file, access);
        assert_eq!(lo.sysfs("ro").as_deref(), Some(ro), "{access:?}");
        assert_eq!(lo.sysfs("loop/autoclear").as_deref(), Some("1"));
        assert_eq!(
            lo.sysfs("loop/backing_file").map(PathBuf::from),
            Some(file.clone())
        );
        let landed = write_lands(&lo.path, &file, 0x7c);
        assert_eq!(landed, access == Access::ReadWrite, "{access:?}");
        lo.release();
        assert!(
            lo.detached_within(Duration::from_secs(3)),
            "{:?} leaked after its last holder closed",
            lo.path
        );
    }
}

struct DmGuard(Vec<String>);

impl Drop for DmGuard {
    fn drop(&mut self) {
        for n in self.0.iter().rev() {
            let _ = Command::new(DMSETUP)
                .args(["remove", "--retry", n])
                .output();
        }
    }
}

fn live_dmsetup() -> Option<Dmsetup> {
    RootSafeBin::open(Path::new(DMSETUP)).ok().map(Dmsetup::new)
}

#[test]
fn a_live_linear_table_is_sized_numbered_and_protected_as_requested_as_root() {
    require_root!();
    let Some(dm) = live_dmsetup() else {
        eprintln!("SKIP: no root-owned {DMSETUP}");
        return;
    };
    let dir = TempDir::new().unwrap();
    let file = real(&dir).join("disk.img");
    let sectors = 2048;
    fs::write(&file, vec![0x5a; sectors as usize * 512]).unwrap();
    let mut lo = Loop::attach(&file, Access::ReadOnly);
    let n = format!("hyper-t-lin-{}", std::process::id());
    let _guard = DmGuard(vec![n.clone()]);

    let dev = dm
        .create(
            &name(&n),
            &DmTable::Linear(LinearTable {
                sectors,
                origin: Origin::Path(dev_path(&lo.path)),
            }),
            Access::ReadOnly,
        )
        .unwrap();

    assert_eq!(dev.name().sectors().unwrap(), sectors);
    let meta = fs::metadata(dev.path().as_path()).unwrap();
    assert!(meta.file_type().is_block_device());
    assert_eq!(dev.number().unwrap(), DeviceNumber::from(meta.rdev()));
    assert!(!write_lands(dev.path().as_path(), &file, 0x7c));
    let mut head = [0u8; 512];
    fs::File::open(dev.path().as_path())
        .unwrap()
        .read_exact(&mut head)
        .unwrap();
    assert_eq!(head, [0x5a; 512]);

    let path = dev.path();
    dev.remove(RemoveMode::Retry).unwrap();
    assert!(!path.as_path().exists());
    lo.release();
    assert!(lo.detached_within(Duration::from_secs(3)), "loop leaked");
}

struct FakeThinDump {
    _dir: TempDir,
    base: PathBuf,
    dump: ThinDump,
}

impl FakeThinDump {
    fn new(xml: &str) -> Self {
        let dir = TempDir::new().unwrap();
        let base = real(&dir);
        fs::write(base.join("dump.xml"), xml).unwrap();
        let bin = install(
            &base,
            "thin_dump",
            &format!(
                "printf '%s\\0' \"$@\" > '{b}/argv'\n\
                 /usr/bin/head -c 16 \"$4\" > '{b}/seen'\n\
                 /bin/cat '{b}/dump.xml'\n",
                b = base.display()
            ),
        );
        Self {
            dump: ThinDump::new(RootSafeBin::open(&bin).unwrap()),
            _dir: dir,
            base,
        }
    }
}

fn superblock(devices: &str) -> String {
    format!(
        "<superblock uuid=\"\" time=\"0\" transaction=\"1\" flags=\"0\" version=\"2\" data_block_size=\"128\" nr_data_blocks=\"16\">{devices}</superblock>"
    )
}

fn metadata_device(dir: &Path, marker: &[u8; 16]) -> (Loop, SafeFile<IsBlockDevice, Any, Any>) {
    let file = dir.join("meta.img");
    let mut contents = marker.to_vec();
    contents.resize(1 << 20, 0);
    fs::write(&file, contents).unwrap();
    let lo = Loop::attach(&file, Access::ReadOnly);
    let dev = SafeFile::open(&dev_path(&lo.path), OpenFlags::RDONLY).unwrap();
    (lo, dev)
}

#[test]
fn thin_dump_reads_the_metadata_through_the_inherited_fd_as_root() {
    require_root!();
    let fake = FakeThinDump::new(&superblock(
        "<device dev_id=\"5\" mapped_blocks=\"3\" transaction=\"0\" creation_time=\"0\" snap_time=\"0\"><range_mapping origin_begin=\"2\" data_begin=\"0\" length=\"2\" time=\"0\"/><single_mapping origin_block=\"9\" data_block=\"4\" time=\"0\"/></device>",
    ));
    let marker = *b"hyper-meta-probe";
    let (_lo, meta) = metadata_device(&fake.base, &marker);
    let id = ThinId::new(5).unwrap();

    let dumped = fake.dump.dump(&meta, id).unwrap();

    let argv = recorded_argv(&fake.base.join("argv"));
    assert_eq!(argv[..3], ["--metadata-snap", "--dev-id", "5"]);
    assert_eq!(argv.len(), 4, "{argv:?}");
    assert!(argv[3].starts_with("/proc/self/fd/"), "{argv:?}");
    assert_eq!(fs::read(fake.base.join("seen")).unwrap(), marker);
    assert_eq!(
        dumped.parse().unwrap().mappings(id).unwrap().ranges,
        [
            BlockRange {
                begin: 2,
                length: 2
            },
            BlockRange {
                begin: 9,
                length: 1
            }
        ]
    );
}

#[test]
fn a_mapping_total_that_overflows_is_refused_not_a_panic_as_root() {
    require_root!();
    let fake = FakeThinDump::new(&superblock(&format!(
        "<device dev_id=\"5\" mapped_blocks=\"0\" transaction=\"0\" creation_time=\"0\" snap_time=\"0\"><range_mapping origin_begin=\"0\" data_begin=\"0\" length=\"{}\" time=\"0\"/><single_mapping origin_block=\"9\" data_block=\"4\" time=\"0\"/></device>",
        u64::MAX
    )));
    let (_lo, meta) = metadata_device(&fake.base, b"0123456789abcdef");
    let id = ThinId::new(5).unwrap();
    let superblock = fake.dump.dump(&meta, id).unwrap().parse().unwrap();

    let got = std::panic::catch_unwind(|| superblock.mappings(id));

    assert!(
        matches!(got, Ok(Err(MappingsError::Truncated { .. }))),
        "{got:?}"
    );
}

#[test]
fn a_failing_thin_dump_is_an_error_not_an_empty_dump_as_root() {
    require_root!();
    let dir = TempDir::new().unwrap();
    let base = real(&dir);
    let bin = install(
        &base,
        "thin_dump",
        "printf '<superblock data_block_size=\"128\"></superblock>'\nprintf ' no metadata snap \\n' >&2\nexit 1\n",
    );
    let dump = ThinDump::new(RootSafeBin::open(&bin).unwrap());
    let (_lo, meta) = metadata_device(&base, b"0123456789abcdef");

    let err = dump.dump(&meta, ThinId::new(1).unwrap()).unwrap_err();

    assert_eq!(err.to_string(), "thin_dump failed: no metadata snap");
}

struct LivePool {
    _dir: TempDir,
    _meta: Loop,
    _data: Loop,
    meta_dev: SafeFile<IsBlockDevice, Any, Any>,
    guard: DmGuard,
    pool: DmName,
    dm: Dmsetup,
}

const POOL_DATA_BYTES: u64 = 32 << 20;
const VOLUME_SECTORS: u64 = 16 << 11;
const VOLUME_BLOCKS: u64 = VOLUME_SECTORS / BLOCK_SECTORS;

impl LivePool {
    fn new(tag: &str) -> Option<Self> {
        let dm = live_dmsetup()?;
        let dir = TempDir::new().unwrap();
        let base = real(&dir);
        sparse(&base.join("meta.img"), 8 << 20);
        sparse(&base.join("data.img"), POOL_DATA_BYTES);
        let meta = Loop::attach(&base.join("meta.img"), Access::ReadWrite);
        let data = Loop::attach(&base.join("data.img"), Access::ReadWrite);
        let pool = format!("hyper-t-{tag}-pool-{}", std::process::id());
        let guard = DmGuard(vec![pool.clone()]);
        dm.create(
            &name(&pool),
            &DmTable::ThinPool(ThinPoolTable {
                sectors: POOL_DATA_BYTES / 512,
                metadata: dev_path(&meta.path),
                data: dev_path(&data.path),
                block_sectors: BLOCK_SECTORS,
                low_water: 0,
            }),
            Access::ReadWrite,
        )
        .ok()?;
        let meta_dev = SafeFile::open(&dev_path(&meta.path), OpenFlags::RDONLY).unwrap();
        Some(Self {
            _dir: dir,
            _meta: meta,
            _data: data,
            meta_dev,
            guard,
            pool: name(&pool),
            dm,
        })
    }

    fn volume_name(&mut self, suffix: &str) -> DmName {
        let n = format!("{}-{suffix}", self.pool);
        self.guard.0.push(n.clone());
        name(&n)
    }
}

fn write_block(dev: &Path, block: u64, fill: u8) {
    let mut f = fs::OpenOptions::new().write(true).open(dev).unwrap();
    f.seek(SeekFrom::Start(block * BLOCK_BYTES)).unwrap();
    f.write_all(&vec![fill; BLOCK_BYTES as usize]).unwrap();
    f.sync_all().unwrap();
}

fn read_block(dev: &Path, block: u64) -> Vec<u8> {
    let mut f = fs::File::open(dev).unwrap();
    f.seek(SeekFrom::Start(block * BLOCK_BYTES)).unwrap();
    let mut buf = vec![0u8; BLOCK_BYTES as usize];
    f.read_exact(&mut buf).unwrap();
    buf
}

fn mapped_blocks(pool: &LivePool, id: ThinId) -> BTreeSet<u64> {
    let thin_pool = pool.dm.thin_pool(&pool.pool).unwrap();
    let dump = ThinDump::new(RootSafeBin::open(Path::new(THIN_DUMP)).unwrap());
    thin_pool.reserve_metadata_snap().unwrap();
    let dumped = dump.dump(&pool.meta_dev, id);
    thin_pool.release_metadata_snap().unwrap();
    dumped
        .unwrap()
        .parse()
        .unwrap()
        .mappings(id)
        .unwrap()
        .ranges
        .iter()
        .flat_map(|r| r.begin..r.begin + r.length)
        .collect()
}

#[test]
fn a_real_pools_ids_snapshots_and_dumped_mappings_obey_their_laws_as_root() {
    require_root!();
    if RootSafeBin::<"thin_dump">::open(Path::new(THIN_DUMP)).is_err() {
        eprintln!("SKIP: no root-owned {THIN_DUMP}");
        return;
    }
    let Some(mut live) = LivePool::new("laws") else {
        eprintln!("SKIP: dm-thin unavailable");
        return;
    };
    let vol_name = live.volume_name("vol");
    let snap_name = live.volume_name("snap");
    let (one, two) = (ThinId::new(1).unwrap(), ThinId::new(2).unwrap());
    let pool = live.dm.thin_pool(&live.pool).unwrap();

    let vol = pool
        .create_thin(one)
        .unwrap()
        .activate(&vol_name, VOLUME_SECTORS, None)
        .unwrap();
    assert!(
        pool.create_thin(one).is_err(),
        "an id already provisioned was provisioned again"
    );

    let mut runner = proptest::test_runner::TestRunner::deterministic();
    let written: BTreeSet<u64> = prop::collection::btree_set(0..VOLUME_BLOCKS, 1..24)
        .new_tree(&mut runner)
        .unwrap()
        .current();
    for &b in &written {
        write_block(vol.device().path().as_path(), b, (b % 250) as u8 + 1);
    }
    assert_eq!(mapped_blocks(&live, one), written);

    let snap = vol.snapshot(two).unwrap();
    let snap = snap.activate(&snap_name, VOLUME_SECTORS, None).unwrap();
    let first = *written.iter().next().unwrap();
    let before = read_block(vol.device().path().as_path(), first);
    write_block(vol.device().path().as_path(), first, 0xEE);
    let fresh = (0..VOLUME_BLOCKS).find(|b| !written.contains(b)).unwrap();
    write_block(vol.device().path().as_path(), fresh, 0xDD);

    assert_eq!(read_block(snap.device().path().as_path(), first), before);
    assert_eq!(
        read_block(snap.device().path().as_path(), fresh),
        vec![0u8; BLOCK_BYTES as usize]
    );
    assert_eq!(mapped_blocks(&live, two), written);
    let mut grown = written.clone();
    grown.insert(fresh);
    assert_eq!(mapped_blocks(&live, one), grown);

    assert_eq!(pool.open_thin(&vol_name).unwrap().id(), one);
    assert_eq!(pool.open_thin(&snap_name).unwrap().id(), two);

    pool.reserve_metadata_snap().unwrap();
    let second = pool.reserve_metadata_snap();
    pool.release_metadata_snap().unwrap();
    assert!(second.is_err(), "the metadata snapshot was reserved twice");

    snap.deactivate().unwrap().delete().unwrap();
    vol.deactivate().unwrap().delete().unwrap();
    assert!(!vol_name.path().as_path().exists());
    let again = pool.create_thin(one).expect("a deleted id is free again");
    again.delete().unwrap();
}

#[test]
fn a_thin_over_an_external_origin_maps_only_what_diverged_as_root() {
    require_root!();
    if RootSafeBin::<"thin_dump">::open(Path::new(THIN_DUMP)).is_err() {
        eprintln!("SKIP: no root-owned {THIN_DUMP}");
        return;
    }
    let Some(mut live) = LivePool::new("ext") else {
        eprintln!("SKIP: dm-thin unavailable");
        return;
    };
    let dir = TempDir::new().unwrap();
    let origin_file = real(&dir).join("origin.img");
    fs::write(&origin_file, vec![0x11; (VOLUME_SECTORS * 512) as usize]).unwrap();
    let origin_loop = Loop::attach(&origin_file, Access::ReadOnly);
    let origin_name = live.volume_name("origin");
    live.dm
        .create(
            &origin_name,
            &DmTable::Linear(LinearTable {
                sectors: VOLUME_SECTORS,
                origin: Origin::Path(dev_path(&origin_loop.path)),
            }),
            Access::ReadOnly,
        )
        .unwrap();
    let vol_name = live.volume_name("vol");
    let id = ThinId::new(3).unwrap();
    let pool = live.dm.thin_pool(&live.pool).unwrap();
    let vol = pool
        .create_thin(id)
        .unwrap()
        .activate(
            &vol_name,
            VOLUME_SECTORS,
            Some(Origin::Device(origin_name.clone())),
        )
        .unwrap();

    assert_eq!(
        read_block(vol.device().path().as_path(), 5),
        vec![0x11; BLOCK_BYTES as usize]
    );
    assert!(
        mapped_blocks(&live, id).is_empty(),
        "reads must not provision"
    );
    write_block(vol.device().path().as_path(), 5, 0x22);
    write_block(vol.device().path().as_path(), VOLUME_BLOCKS - 1, 0x33);

    assert_eq!(
        mapped_blocks(&live, id),
        BTreeSet::from([5, VOLUME_BLOCKS - 1])
    );
    assert_eq!(
        fs::read(&origin_file).unwrap(),
        vec![0x11; (VOLUME_SECTORS * 512) as usize]
    );

    vol.deactivate().unwrap().delete().unwrap();
}
