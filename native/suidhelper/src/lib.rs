// `&'static str` const generics (`RootSafeBin<"losetup">`) are nightly-only.
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

//! Library crate for the Hyper suidhelper. All logic lives here so it can be
//! exercised by integration tests under `tests/`; `src/main.rs` is a thin entry
//! point over these modules.

pub mod cli;
pub mod config;
pub mod dm;
pub mod id;
pub mod insecure_mode;
pub mod lock;
pub mod network;
