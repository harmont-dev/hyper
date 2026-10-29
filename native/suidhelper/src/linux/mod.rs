//! Linux-specific utilities

pub mod cgroup;
pub mod dm;
pub mod loopdev;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    ReadOnly,
    ReadWrite,
}
