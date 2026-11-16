//! The caller gate ([`Caller::authorize`]) against an independent model of the #156 contract:
//! "privileged ops run only for root and members of the group the helper is installed with".
//!
//! Laws:
//! - oracle: a caller is authorized iff its uid is 0, or the install group is readable, is not
//!   gid 0, and is the caller's primary or a supplementary gid;
//! - the refusal names the caller's uid and the install group, and a root install group or an
//!   unreadable install refuses every non-root caller with exactly that cause;
//! - membership is a set property: reordering or repeating supplementary gids never changes
//!   the verdict;
//! - root bypass is about the uid alone: gid 0 or membership of gid 0 grants nothing.

use hyper_suidhelper::caller::{Caller, CallerError, NodeGroup};
use nix::errno::Errno;
use nix::unistd::{Gid, Uid};
use proptest::prelude::*;
use test_strategy::proptest;

fn gid() -> impl Strategy<Value = u32> {
    prop_oneof![0u32..4, 990u32..994, any::<u32>()]
}

fn installed() -> impl Strategy<Value = Result<u32, Errno>> {
    prop_oneof![
        8 => gid().prop_map(Ok),
        1 => prop_oneof![Just(Errno::EACCES), Just(Errno::ENOENT), Just(Errno::ELOOP)].prop_map(Err),
    ]
}

fn caller(uid: u32, gid: u32, groups: &[u32]) -> Caller {
    Caller {
        uid: Uid::from_raw(uid),
        gid: Gid::from_raw(gid),
        groups: groups.iter().copied().map(Gid::from_raw).collect(),
    }
}

fn group(installed: Result<u32, Errno>) -> Result<NodeGroup, CallerError> {
    installed
        .map_err(CallerError::Stat)
        .and_then(|g| Gid::from_raw(g).try_into())
}

fn model(
    uid: u32,
    gid: u32,
    groups: &[u32],
    installed: Result<u32, Errno>,
) -> Result<(), CallerError> {
    if uid == 0 {
        return Ok(());
    }
    match installed {
        Err(errno) => Err(CallerError::Stat(errno)),
        Ok(0) => Err(CallerError::RootGroup),
        Ok(g) if gid == g || groups.contains(&g) => Ok(()),
        Ok(g) => Err(CallerError::NotInGroup {
            uid: Uid::from_raw(uid),
            group: Gid::from_raw(g),
        }),
    }
}

#[proptest]
fn authorize_agrees_with_the_model(
    #[strategy(prop_oneof![Just(0u32), 1u32..3, 1000u32..1003, any::<u32>()])] uid: u32,
    #[strategy(gid())] gid: u32,
    #[strategy(proptest::collection::vec(gid(), 0..40))] groups: Vec<u32>,
    #[strategy(installed())] installed: Result<u32, Errno>,
) {
    prop_assert_eq!(
        caller(uid, gid, &groups).authorize(group(installed)),
        model(uid, gid, &groups, installed)
    );
}

#[proptest]
fn a_member_anywhere_in_a_long_group_list_is_authorized(
    #[strategy(1u32..)] uid: u32,
    #[strategy(1u32..)] node: u32,
    #[strategy(proptest::collection::vec(any::<u32>(), 0..2_000))] others: Vec<u32>,
    at: usize,
) {
    let mut groups: Vec<u32> = others.into_iter().filter(|&g| g != node).collect();
    let primary = groups.pop().unwrap_or(node.wrapping_add(1).max(1));
    prop_assume!(primary != node);
    prop_assert!(caller(uid, primary, &groups)
        .authorize(group(Ok(node)))
        .is_err());
    groups.insert(at % (groups.len() + 1), node);
    prop_assert_eq!(
        caller(uid, primary, &groups).authorize(group(Ok(node))),
        Ok(())
    );
}

#[proptest]
fn reordering_or_repeating_supplementary_groups_never_changes_the_verdict(
    #[strategy(1u32..)] uid: u32,
    #[strategy(gid())] gid: u32,
    #[strategy(proptest::collection::vec(gid(), 1..20))] groups: Vec<u32>,
    #[strategy(gid())] node: u32,
    rotate: usize,
    repeat: usize,
) {
    let verdict = caller(uid, gid, &groups).authorize(group(Ok(node)));
    let mut shuffled = groups.clone();
    shuffled.rotate_left(rotate % groups.len());
    shuffled.reverse();
    shuffled.push(groups[repeat % groups.len()]);
    prop_assert_eq!(
        caller(uid, gid, &shuffled).authorize(group(Ok(node))),
        verdict
    );
}

#[proptest]
fn the_root_group_grants_a_non_root_uid_nothing(
    #[strategy(1u32..)] uid: u32,
    #[strategy(gid())] node: u32,
) {
    let verdict = caller(uid, 0, &[0]).authorize(group(Ok(node)));
    if node == 0 {
        prop_assert_eq!(verdict, Err(CallerError::RootGroup));
    } else {
        prop_assert_eq!(
            verdict,
            Err(CallerError::NotInGroup {
                uid: Uid::from_raw(uid),
                group: Gid::from_raw(node)
            })
        );
    }
}

#[proptest]
fn only_gid_zero_is_refused_as_an_install_group(raw: u32) {
    let parsed = NodeGroup::try_from(Gid::from_raw(raw));
    prop_assert_eq!(parsed.is_err(), raw == 0);
    if raw == 0 {
        prop_assert_eq!(parsed, Err(CallerError::RootGroup));
    }
}
