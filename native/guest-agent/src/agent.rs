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

    async fn exec(&self, req: Request<ExecRequest>) -> Result<Response<ExecResponse>, Status> {
        let r = req.into_inner();
        let env: std::collections::BTreeMap<String, String> = r.env.into_iter().collect();
        let argv = r.argv;
        let cwd = r.cwd;
        let (exit_code, stdout, stderr) =
            tokio::task::spawn_blocking(move || crate::exec::run(&argv, &env, cwd.as_deref()))
                .await
                .map_err(|e| Status::internal(e.to_string()))?;
        Ok(Response::new(ExecResponse {
            exit_code,
            stdout,
            stderr,
        }))
    }
}
