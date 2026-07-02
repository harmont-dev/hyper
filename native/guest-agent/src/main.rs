use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY};

use hyper_guest_agent::{agent, init, pb};

const VSOCK_PORT: u32 = 1024;

fn main() -> ! {
    if let Err(e) = init::setup() {
        eprintln!("hyper-init: mounts failed: {e}");
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build();
    match rt {
        Ok(rt) => {
            let _ = rt.block_on(serve());
        }
        Err(e) => eprintln!("hyper-init: runtime failed: {e}"),
    }
    // PID 1 must never exit; park this thread forever so the kernel does not
    // panic (panic=1 would reboot-loop the guest).
    loop {
        std::thread::park();
    }
}

async fn serve() -> Result<(), Box<dyn std::error::Error>> {
    // Reaper registered before accepting connections: avoids a race where a
    // child exits between fork and SIGCHLD handler registration.
    init::spawn_reaper();
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, VSOCK_PORT))?;
    tonic::transport::Server::builder()
        .add_service(pb::guest_agent_server::GuestAgentServer::new(agent::Agent))
        .serve_with_incoming(listener.incoming())
        .await?;
    Ok(())
}
