// SPDX-License-Identifier: MIT
// `&'static str` const generics (`SafePath::from_static::<"/">`) are nightly-only.
// TODO(markovejnovic): Can we remove these.
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

//! Type-safer filesystem utilities.

pub mod dev;
pub mod dir;
pub mod file;
pub mod lock;
pub mod path;
