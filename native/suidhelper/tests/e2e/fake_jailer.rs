use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;

const RECORDER_EXIT: u8 = 7;

fn main() -> ExitCode {
    let dir: PathBuf = std::env::current_exe()
        .expect("own executable path")
        .parent()
        .expect("executable has a parent directory")
        .to_path_buf();

    let argv: Vec<String> = std::env::args().skip(1).collect();
    fs::write(dir.join("argv.json"), serde_json::to_vec(&argv).unwrap()).unwrap();

    let environ = fs::read("/proc/self/environ").unwrap();
    fs::write(dir.join("environ.bin"), environ).unwrap();

    ExitCode::from(RECORDER_EXIT)
}
