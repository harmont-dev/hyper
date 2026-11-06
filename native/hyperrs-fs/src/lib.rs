// SPDX-License-Identifier: MIT
// `&'static str` const generics (`SafePath::from_static::<"/">`) are nightly-only.
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

//! Filesystem utilities.

pub mod dev;
pub mod dir;
pub mod file;
pub mod path;
