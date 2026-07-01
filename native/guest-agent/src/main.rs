use std::io;

use nix::sys::socket::{
    accept, bind, listen, socket, AddressFamily, Backlog, SockFlag, SockType, VsockAddr,
};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

use hyper_guest_agent::{exec, init};

const VSOCK_PORT: u32 = 1024;

fn main() -> ! {
    if let Err(e) = init::setup() {
        eprintln!("hyper-init: setup failed: {e}");
    }
    // PID 1 must never return; on a fatal listener error, log and park so the
    // kernel does not panic (panic=1 would reboot-loop).
    if let Err(e) = serve() {
        eprintln!("hyper-init: serve failed: {e}");
    }
    loop {
        std::thread::park();
    }
}

fn serve() -> io::Result<()> {
    let sock = socket(
        AddressFamily::Vsock,
        SockType::Stream,
        SockFlag::empty(),
        None,
    )?;
    // VMADDR_CID_ANY == u32::MAX; bind our listening port.
    bind(sock.as_raw_fd(), &VsockAddr::new(u32::MAX, VSOCK_PORT))?;
    listen(&sock, Backlog::new(8).unwrap())?;
    loop {
        let fd = accept(sock.as_raw_fd())?;
        // One command per connection; serve serially (v1). A bad request only
        // closes this connection.
        let owned = unsafe { OwnedFd::from_raw_fd(fd) };
        let mut stream = std::os::unix::net::UnixStream::from(owned);
        let _ = exec::serve_one(&mut stream.try_clone()?, &mut stream);
    }
}
