use std::collections::BTreeMap;
use std::process::{Command, Stdio};

// Lightweight input/output types shared between this module and tests.
// Task 4 will replace these with the gRPC ExecRequest/ExecResponse from pb.
pub struct Request {
    pub argv: Vec<String>,
    pub env: BTreeMap<String, String>,
    pub cwd: Option<String>,
    pub timeout_ms: Option<u64>,
}

pub struct Response {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

pub fn run(req: &Request) -> Response {
    let Some((program, args)) = req.argv.split_first() else {
        return Response {
            exit_code: 127,
            stdout: vec![],
            stderr: b"empty argv".to_vec(),
        };
    };

    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = &req.cwd {
        cmd.current_dir(cwd);
    }
    if !req.env.is_empty() {
        cmd.env_clear().envs(&req.env);
    }

    match cmd.output() {
        Ok(out) => Response {
            // No exit code when killed by a signal; return -1 per spec.
            exit_code: out.status.code().unwrap_or(-1),
            stdout: out.stdout,
            stderr: out.stderr,
        },
        Err(e) => Response {
            exit_code: 127,
            stdout: vec![],
            stderr: e.to_string().into_bytes(),
        },
    }
}
