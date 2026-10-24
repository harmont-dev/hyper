pub mod agent;
pub mod exec;
pub mod init;

// tonic-generated code: lints in it are not ours to fix, and newer clippy
// releases keep flagging it (e.g. `double_must_use` on async_trait methods).
#[allow(clippy::all)]
pub mod pb {
    tonic::include_proto!("hyper.agent.v1");
}
