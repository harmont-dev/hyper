//! Wire protocol between the Elixir guest-exec client and this agent.
//!
//! **Request** (Elixir client → agent): the client `CBOR.encode`s a map and
//! sends the bytes directly — no length prefix, no delimiter. The agent reads
//! exactly one self-delimiting CBOR value via `ciborium::from_reader`, which
//! stops at the end of the definite-length map without needing EOF.
//!
//! **Response** (agent → client): the agent `ciborium::into_writer`s a
//! [`Response`] map and then **closes the connection**. The client reads the
//! socket to EOF, then calls `CBOR.decode` on the accumulated bytes.
//!
//! `stdout` and `stderr` are CBOR **byte strings** (major type 2), encoded via
//! `serde_bytes` on the Rust side and unwrapped from `%CBOR.Tag{tag: :bytes}`
//! on the Elixir side, so raw binary data round-trips without base64.

use std::collections::BTreeMap;
use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub argv: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Response {
    pub exit_code: i32,
    #[serde(with = "serde_bytes")]
    pub stdout: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub stderr: Vec<u8>,
}

pub fn read_request(r: impl Read) -> io::Result<Request> {
    ciborium::from_reader(r).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))
}

pub fn write_request(mut w: impl Write, req: &Request) -> io::Result<()> {
    ciborium::into_writer(req, &mut w).map_err(|e| io::Error::other(e.to_string()))?;
    w.flush()
}

pub fn write_response(mut w: impl Write, resp: &Response) -> io::Result<()> {
    ciborium::into_writer(resp, &mut w).map_err(|e| io::Error::other(e.to_string()))?;
    w.flush()
}

pub fn read_response(r: impl Read) -> io::Result<Response> {
    ciborium::from_reader(r).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e.to_string()))
}
