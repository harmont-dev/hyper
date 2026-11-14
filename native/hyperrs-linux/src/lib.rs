// SPDX-License-Identifier: MIT
// `&'static str` const generics (`RootSafeBin<"dmsetup">`) are nightly-only.
//
// TODO(markovejnovic): Can we avoid these incomplete features?
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

//! Linux-specific utilities

pub mod cgroup;
pub mod dm;
pub mod loopdev;
pub mod net;
pub mod netns;
pub mod sysctl;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    ReadOnly,
    ReadWrite,
}
