use std::collections::BTreeMap;
use std::process::{Command, Stdio};

pub fn run(
    argv: &[String],
    env: &BTreeMap<String, String>,
    cwd: Option<&str>,
) -> (i32, Vec<u8>, Vec<u8>) {
    let Some((program, args)) = argv.split_first() else {
        return (127, vec![], b"empty argv".to_vec());
    };
    let mut cmd = Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(c) = cwd {
        cmd.current_dir(c);
    }
    if !env.is_empty() {
        cmd.env_clear().envs(env);
    }
    match cmd.output() {
        Ok(o) => (o.status.code().unwrap_or(-1), o.stdout, o.stderr),
        Err(e) => (127, vec![], e.to_string().into_bytes()),
    }
}
