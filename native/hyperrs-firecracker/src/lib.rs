// SPDX-License-Identifier: MIT
#![feature(adt_const_params)]
#![feature(unsized_const_params)]
#![allow(incomplete_features)]

pub mod jailer;
mod tun;
mod vm_id;

pub use vm_id::{VmId, VmIdError};
