// SPDX-License-Identifier: MIT

use nix::errno::Errno;
use nix::sys::stat::stat;
use nix::unistd::{getgid, getgroups, getuid, Gid, Uid};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError, PartialEq, Eq)]
pub enum CallerError {
    #[error(
        "hyper-suidhelper is installed with group root, so only root may run it; \
         reinstall it root:<node group> mode 4750 (mix suidhelper.install)"
    )]
    RootGroup,
    #[error("reading the helper's install group: {0}")]
    Stat(#[source] Errno),
    #[error("listing the caller's groups: {0}")]
    Groups(#[source] Errno),
    #[error("uid {uid} is not in the helper's group {group}; only that group and root may run it")]
    NotInGroup { uid: Uid, group: Gid },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NodeGroup(Gid);

impl TryFrom<Gid> for NodeGroup {
    type Error = CallerError;

    fn try_from(gid: Gid) -> Result<Self, Self::Error> {
        if gid.as_raw() == 0 {
            return Err(CallerError::RootGroup);
        }
        Ok(Self(gid))
    }
}

impl NodeGroup {
    pub fn installed() -> Result<Self, CallerError> {
        let exe = stat("/proc/self/exe").map_err(CallerError::Stat)?;
        Gid::from_raw(exe.st_gid).try_into()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Caller {
    pub uid: Uid,
    pub gid: Gid,
    pub groups: Vec<Gid>,
}

impl Caller {
    pub fn current() -> Result<Self, CallerError> {
        Ok(Self {
            uid: getuid(),
            gid: getgid(),
            groups: getgroups().map_err(CallerError::Groups)?,
        })
    }

    pub fn authorize(&self, group: Result<NodeGroup, CallerError>) -> Result<(), CallerError> {
        if self.uid.is_root() {
            return Ok(());
        }
        let NodeGroup(group) = group?;
        if self.gid != group && !self.groups.contains(&group) {
            return Err(CallerError::NotInGroup {
                uid: self.uid,
                group,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{Caller, CallerError, NodeGroup};
    use nix::errno::Errno;
    use nix::unistd::{Gid, Uid};
    use pretty_assertions::assert_eq;
    use rstest::rstest;

    const NODE: u32 = 990;

    fn caller(uid: u32, gid: u32, groups: &[u32]) -> Caller {
        Caller {
            uid: Uid::from_raw(uid),
            gid: Gid::from_raw(gid),
            groups: groups.iter().copied().map(Gid::from_raw).collect(),
        }
    }

    fn group(gid: u32) -> Result<NodeGroup, CallerError> {
        Gid::from_raw(gid).try_into()
    }

    #[rstest]
    #[case::root_beside_a_node_group(caller(0, 0, &[]), group(NODE))]
    #[case::root_beside_a_root_group(caller(0, 0, &[]), group(0))]
    #[case::root_when_the_group_is_unreadable(caller(0, 0, &[]), Err(CallerError::Stat(Errno::EACCES)))]
    #[case::the_node_groups_primary_member(caller(1001, NODE, &[]), group(NODE))]
    #[case::a_supplementary_member(caller(1001, 100, &[27, NODE]), group(NODE))]
    fn root_and_members_of_the_node_group_are_authorized(
        #[case] caller: Caller,
        #[case] group: Result<NodeGroup, CallerError>,
    ) {
        assert_eq!(caller.authorize(group), Ok(()));
    }

    #[rstest]
    #[case::a_non_member(caller(1001, 100, &[27]), group(NODE), CallerError::NotInGroup {
        uid: Uid::from_raw(1001), group: Gid::from_raw(NODE) })]
    #[case::anyone_while_the_group_is_root(caller(1001, 0, &[0]), group(0), CallerError::RootGroup)]
    #[case::anyone_when_the_group_is_unreadable(caller(1001, NODE, &[]),
        Err(CallerError::Stat(Errno::EACCES)), CallerError::Stat(Errno::EACCES))]
    fn everyone_else_is_refused(
        #[case] caller: Caller,
        #[case] group: Result<NodeGroup, CallerError>,
        #[case] refusal: CallerError,
    ) {
        assert_eq!(caller.authorize(group), Err(refusal));
    }
}
