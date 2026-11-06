// SPDX-License-Identifier: MIT
// `&'static str` const generics (`RootSafeBin<"losetup">`) are nightly-only.
//
// TOD(markovejnovic): Can we avoid these incomplete features?
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

pub mod binary;
pub mod privilege;
