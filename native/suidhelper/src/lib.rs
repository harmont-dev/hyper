// `&'static str` const generics (`SafeBin<"losetup">`) are nightly-only.
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

//! Library crate for the Hyper suidhelper. All logic lives here so it can be
//! exercised by integration tests under `tests/`; `src/main.rs` is a thin entry
//! point over these modules.

pub mod config;
pub mod tools;
pub mod util;
