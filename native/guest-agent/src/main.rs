use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY};

use hyper_guest_agent::{agent, init, pb};

const VSOCK_PORT: u32 = 1024;

fn main() -> ! {
    // Mount /proc, /sys, /dev BEFORE handing off to pid1. When we are PID 1,
    // pid1's launch() re-execs this binary via std::env::current_exe(), which
    // reads /proc/self/exe — /proc must already be mounted or that read fails,
    // pid1 unwraps the error and panics, and (panic=abort) PID 1 aborts into a
    // panic=1 reboot loop. The re-exec'd child re-enters main() and runs setup()
    // again, but that is a harmless best-effort re-mount over the mounts it
    // already inherited through the shared mount namespace.
    if let Err(e) = init::setup() {
        eprintln!("hyper-init: mounts failed: {e}");
    }

    // When run as PID 1, pid1-rs re-execs this binary as a child, stays in the
    // parent forwarding SIGTERM/SIGINT and reaping zombies/orphans, and never
    // returns here. The re-exec'd child runs with a non-1 PID, so launch()
    // returns immediately and it continues below. When not PID 1 (e.g. under
    // tests) it is a no-op.
    let mut pid1 = pid1::Pid1Settings::new();
    pid1.enable_log(true);
    if let Err(e) = pid1.launch() {
        eprintln!("hyper-init: pid1 launch failed: {e}");
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
    // The re-exec'd child is not PID 1, but if it returned the pid1-rs parent
    // would exit and the kernel would panic (panic=1 → reboot loop). Park
    // forever so the agent process never returns.
    loop {
        std::thread::park();
    }
}

async fn serve() -> Result<(), Box<dyn std::error::Error>> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, VSOCK_PORT))?;
    tonic::transport::Server::builder()
        .add_service(pb::guest_agent_server::GuestAgentServer::new(agent::Agent))
        .serve_with_incoming(listener.incoming())
        .await?;
    Ok(())
}
