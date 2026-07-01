use std::io::{self, Read, Write};
use std::process::{Command, Stdio};

use crate::wire::{read_request, write_response, Request, Response};

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
        cmd.env_clear().envs(req.env.iter().map(|(k, v)| (k, v)));
    }

    match cmd.output() {
        Ok(out) => Response {
            // 128+signal when killed by a signal (no exit code); mirrors shells.
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

pub fn serve_one(reader: &mut impl Read, writer: &mut impl Write) -> io::Result<()> {
    let req = read_request(reader)?;
    let resp = run(&req);
    write_response(writer, &resp)
}
