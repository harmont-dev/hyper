// SPDX-License-Identifier: MIT
//! Confined, race-free filesystem access for code that runs as root.
//!
//! Three layers, each a proof the next can rely on:
//!   * [`path`] — a [`SafePath`](path::SafePath) is a *name* that passed its
//!     lexical checks (absolute, no `.`/`..`/empty components).
//!   * [`file`](mod@file) — a [`SafeFile`](file::SafeFile) is an *open fd* whose type,
//!     owner and mode were verified with a single `fstat`.
//!   * [`dir`] — a [`SafeDir`](dir::SafeDir) is a pinned directory fd; every
//!     walk and mutation is `*at`-relative to it, so no step re-resolves a path
//!     by name.

pub mod dir;
pub mod file;
pub mod path;
