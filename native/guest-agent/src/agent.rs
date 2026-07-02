use tonic::{Request, Response, Status};

use crate::pb::guest_agent_server::GuestAgent;
use crate::pb::{ExecRequest, ExecResponse, HealthRequest, HealthResponse};

#[derive(Default)]
pub struct Agent;

#[tonic::async_trait]
impl GuestAgent for Agent {
    async fn health(
        &self,
        _req: Request<HealthRequest>,
    ) -> Result<Response<HealthResponse>, Status> {
        Ok(Response::new(HealthResponse { ok: true }))
    }

    async fn exec(&self, _req: Request<ExecRequest>) -> Result<Response<ExecResponse>, Status> {
        Err(Status::unimplemented("exec: implemented in the next task"))
    }
}
