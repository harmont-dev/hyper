// Spike harness: a minimal tonic GuestAgent server that listens on a Unix
// domain socket.  Used by the Elixir integration test to prove that
// grpc-elixir (Gun adapter) can speak HTTP/2 over a byte-pipe relay to a
// tonic server without a VM in the loop.
//
// Usage: health_uds <socket-path>

use std::env;

use tokio::net::UnixListener;
use tokio_stream::wrappers::UnixListenerStream;
use tonic::{transport::Server, Request, Response, Status};

mod pb {
    tonic::include_proto!("hyper.agent.v1");
}

use pb::guest_agent_server::{GuestAgent, GuestAgentServer};
use pb::{ExecRequest, ExecResponse, HealthRequest, HealthResponse};

struct MinimalAgent;

#[tonic::async_trait]
impl GuestAgent for MinimalAgent {
    async fn exec(&self, _req: Request<ExecRequest>) -> Result<Response<ExecResponse>, Status> {
        Err(Status::unimplemented("exec"))
    }

    async fn health(
        &self,
        _req: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        Ok(Response::new(HealthResponse { ok: true }))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = env::args().nth(1).expect("usage: health_uds <socket-path>");
    let _ = std::fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    eprintln!("health_uds: listening on {path}");
    Server::builder()
        .add_service(GuestAgentServer::new(MinimalAgent))
        .serve_with_incoming(UnixListenerStream::new(listener))
        .await?;
    Ok(())
}
