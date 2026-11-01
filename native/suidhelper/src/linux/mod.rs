//! Linux-specific utilities

pub mod cgroup;
pub mod dm;
pub mod loopdev;
pub mod netns;
pub mod tun;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    ReadOnly,
    ReadWrite,
}
