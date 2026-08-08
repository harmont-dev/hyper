//! Forwards vsock connections to the guest's Docker daemon.
//!
//! The host drives Docker inside the guest. Reaching it over IP means exposing
//! the daemon's unauthenticated API on the guest's network address and poking a
//! matching hole in the host's firewall — anyone who reaches that port gets
//! root-equivalent control of the guest. vsock is point-to-point between the
//! host and this VM by construction, so the daemon stays bound to its Unix
//! socket and never appears on a network at all.

use std::io;
use std::path::Path;

use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::UnixStream;
use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY};

/// vsock port the host dials for the Docker API. Distinct from the agent's
/// gRPC port; the same vsock device multiplexes both.
pub const DOCKER_VSOCK_PORT: u32 = 2375;

/// Where dockerd listens inside the guest.
pub const DOCKER_SOCKET: &str = "/var/run/docker.sock";

/// Pipe one accepted connection to the Docker daemon until either side closes.
///
/// Generic over the client stream so the forwarding contract is testable
/// without a live vsock device. Bidirectional on purpose: the Docker API
/// hijacks the connection for `exec` streaming, so a one-way copy would hang
/// every interactive session.
pub async fn proxy_to_docker<S>(mut client: S, socket: &Path) -> io::Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut upstream = UnixStream::connect(socket).await?;
    tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
    Ok(())
}

/// Accept Docker connections on vsock forever, one task per connection.
///
/// A failed proxy attempt is logged and dropped rather than propagated: the
/// host retries while dockerd is still starting, and one refused connection
/// must not take the listener down with it.
pub async fn serve(port: u32, socket: &'static str) -> io::Result<()> {
    let listener = VsockListener::bind(VsockAddr::new(VMADDR_CID_ANY, port))?;
    loop {
        match listener.accept().await {
            Ok((stream, _addr)) => {
                tokio::spawn(async move {
                    if let Err(e) = proxy_to_docker(stream, Path::new(socket)).await {
                        eprintln!("hyper-init: docker proxy connection failed: {e}");
                    }
                });
            }
            Err(e) => eprintln!("hyper-init: docker proxy accept failed: {e}"),
        }
    }
}
