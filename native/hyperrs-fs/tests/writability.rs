// SPDX-License-Identifier: MIT

use assert_fs::prelude::*;
use assert_fs::TempDir;
use hyperrs_fs::file::{
    Any, IsDirectory, OpenFlags, SafeFile, StickyOrOwnerOnlyWritable, ValidationError,
};
use hyperrs_fs::path::{IsAbsolute, SafePathBuf, StrictComponents};
use rstest::rstest;
use std::assert_matches;
use std::fs;
use std::os::unix::fs::PermissionsExt;

#[rstest]
#[case::owner_only(0o755, true)]
#[case::owner_only_private(0o700, true)]
#[case::sticky_world_writable(0o1777, true)]
#[case::sticky_group_writable(0o1775, true)]
#[case::group_writable(0o775, false)]
#[case::other_writable(0o757, false)]
#[case::world_writable(0o777, false)]
fn a_directory_is_accepted_exactly_when_sticky_or_writable_only_by_its_owner(
    #[case] mode: u32,
    #[case] accepted: bool,
) {
    let tmp = TempDir::new().unwrap();
    let dir = tmp.child("d");
    dir.create_dir_all().unwrap();
    fs::set_permissions(&dir, fs::Permissions::from_mode(mode)).unwrap();
    let path: SafePathBuf<IsAbsolute, StrictComponents> =
        dir.path().to_path_buf().try_into().unwrap();

    let got = SafeFile::<IsDirectory, Any, StickyOrOwnerOnlyWritable>::open(&path, OpenFlags::PATH);

    if accepted {
        assert!(got.is_ok(), "{mode:o}: {got:?}");
    } else {
        assert_matches!(got, Err(ValidationError::GroupOrOtherWritable));
    }
}
