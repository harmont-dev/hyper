//! Tests for the vsock -> Docker socket forwarder.
//!
//! Invariants exercised:
//!
//! - Bytes flow in both directions between the accepted client and the Docker
//!   daemon's Unix socket, since the Docker API hijacks the connection for
//!   `exec` streaming and a one-way copy would hang those sessions.
//! - A missing Docker socket surfaces as an error rather than hanging, so a
//!   caller connecting before dockerd is up fails fast.
//!
//! The vsock listener itself needs a live VM, so it is covered by the
//! end-to-end suite rather than here; `proxy_to_docker` is generic over the
//! client stream precisely so the forwarding contract can be tested over an
//! in-memory duplex.

use hyper_guest_agent::docker_proxy::proxy_to_docker;
use std::path::PathBuf;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;

fn temp_socket_path(tag: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    p.push(format!(
        "hyper-docker-proxy-{tag}-{}.sock",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&p);
    p
}

#[tokio::test]
async fn forwards_bytes_in_both_directions() {
    let path = temp_socket_path("both-ways");
    let listener = UnixListener::bind(&path).expect("bind stub docker socket");

    // Stub "dockerd": read a request, answer with a canned response.
    let server = tokio::spawn(async move {
        let (mut sock, _) = listener.accept().await.expect("accept");
        let mut buf = [0u8; 4];
        sock.read_exact(&mut buf).await.expect("read request");
        assert_eq!(&buf, b"PING");
        sock.write_all(b"PONG").await.expect("write response");
    });

    let (mut client, proxy_side) = tokio::io::duplex(1024);
    let p = path.clone();
    let proxy = tokio::spawn(async move { proxy_to_docker(proxy_side, &p).await });

    client.write_all(b"PING").await.expect("client writes");
    let mut got = [0u8; 4];
    client
        .read_exact(&mut got)
        .await
        .expect("client reads reply");
    assert_eq!(&got, b"PONG", "reply must flow back to the client");

    // The copy only finishes once both directions see EOF; drop the client end
    // so the proxy task can return rather than blocking this test forever.
    drop(client);

    server.await.expect("stub server task");
    let _ = proxy.await.expect("proxy task");
    let _ = std::fs::remove_file(&path);
}

#[tokio::test]
async fn missing_docker_socket_is_an_error_not_a_hang() {
    let path = temp_socket_path("absent");
    let (_client, proxy_side) = tokio::io::duplex(64);

    let result = proxy_to_docker(proxy_side, &path).await;

    assert!(
        result.is_err(),
        "connecting with no daemon listening must fail rather than block"
    );
}
