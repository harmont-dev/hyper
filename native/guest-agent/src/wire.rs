use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub argv: Vec<String>,
    #[serde(default)]
    pub env: Vec<(String, String)>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Response {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

fn read_u32(r: &mut impl Read) -> io::Result<u32> {
    let mut b = [0u8; 4];
    r.read_exact(&mut b)?;
    Ok(u32::from_be_bytes(b))
}

fn read_frame(r: &mut impl Read) -> io::Result<Vec<u8>> {
    let len = read_u32(r)? as usize;
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

fn write_frame(w: &mut impl Write, bytes: &[u8]) -> io::Result<()> {
    w.write_all(&(bytes.len() as u32).to_be_bytes())?;
    w.write_all(bytes)
}

pub fn read_request(r: &mut impl Read) -> io::Result<Request> {
    let frame = read_frame(r)?;
    serde_json::from_slice(&frame).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}

pub fn write_request(w: &mut impl Write, req: &Request) -> io::Result<()> {
    let json = serde_json::to_vec(req)?;
    write_frame(w, &json)
}

pub fn write_response(w: &mut impl Write, resp: &Response) -> io::Result<()> {
    w.write_all(&resp.exit_code.to_be_bytes())?;
    write_frame(w, &resp.stdout)?;
    write_frame(w, &resp.stderr)?;
    w.flush()
}

pub fn read_response(r: &mut impl Read) -> io::Result<Response> {
    let mut code = [0u8; 4];
    r.read_exact(&mut code)?;
    let stdout = read_frame(r)?;
    let stderr = read_frame(r)?;
    Ok(Response {
        exit_code: i32::from_be_bytes(code),
        stdout,
        stderr,
    })
}
