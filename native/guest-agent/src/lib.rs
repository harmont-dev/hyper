pub mod agent;
pub mod exec;
pub mod init;

pub mod pb {
    tonic::include_proto!("hyper.agent.v1");
}
