// SPDX-License-Identifier: MIT

use super::link::{Link, LinkError};
use super::netns::NetNs;
use super::route::{Route, RouteError};
use super::{IfIndex, IfName};
use netlink_packet_core::{
    DecodeError, ErrorMessage, NetlinkMessage, NetlinkPayload, NLM_F_ACK, NLM_F_CREATE, NLM_F_EXCL,
    NLM_F_REQUEST,
};
use netlink_packet_route::link::{
    InfoData, InfoKind, InfoVeth, LinkAttribute, LinkInfo, LinkMessage,
};
use netlink_packet_route::route::{RouteProtocol, RouteScope, RouteType};
use netlink_packet_route::RouteNetlinkMessage;
use netlink_sys::protocols::NETLINK_ROUTE;
use netlink_sys::{Socket, SocketAddr};
use nix::errno::Errno;
use std::io;
use std::os::fd::{AsFd, AsRawFd};
use thiserror::Error as ThisError;

#[derive(Debug, ThisError)]
#[error("opening an rtnetlink socket: {0}")]
pub struct RtnlOpenError(#[source] io::Error);

#[derive(Debug, ThisError)]
pub enum RequestError {
    #[error("sending to rtnetlink: {0}")]
    Send(#[source] io::Error),
    #[error("receiving from rtnetlink: {0}")]
    Recv(#[source] io::Error),
    #[error("decoding the rtnetlink reply: {0}")]
    Decode(#[source] DecodeError),
    #[error("kernel refused the request: {0}")]
    Kernel(#[source] Errno),
    #[error("unexpected rtnetlink reply of type {0}")]
    Unexpected(u16),
}

/// An active connection to rtnetlink.
pub struct Rtnl(Socket);

impl Rtnl {
    /// Open a socket in the calling thread's network namespace.
    pub fn open() -> Result<Self, RtnlOpenError> {
        let mut socket = Socket::new(NETLINK_ROUTE).map_err(RtnlOpenError)?;
        socket.bind_auto().map_err(RtnlOpenError)?;
        socket
            .connect(&SocketAddr::new(0, 0))
            .map_err(RtnlOpenError)?;
        Ok(Self(socket))
    }

    /// Look up the link named `name`, if any.
    pub fn link(&self, name: &IfName) -> Result<Option<Link<'_>>, LinkError> {
        let mut request = LinkMessage::default();
        request
            .attributes
            .push(LinkAttribute::IfName(name.as_str().to_owned()));

        let reply = match self.request(RouteNetlinkMessage::GetLink(request), 0) {
            Ok(reply) => reply,
            Err(RequestError::Kernel(Errno::ENODEV)) => return Ok(None),
            Err(e) => return Err(e.into()),
        };

        let RouteNetlinkMessage::NewLink(link) = reply else {
            return Err(LinkError::UnexpectedReply(Box::new(reply)));
        };

        Ok(Some(Link::new(self, IfIndex::try_from(link.header.index)?)))
    }

    /// Create a veth pair with `peer` placed in `peer_ns`.
    pub fn create_veth(
        &self,
        host: &IfName,
        peer: &IfName,
        peer_ns: &NetNs,
    ) -> Result<Link<'_>, LinkError> {
        let mut peer_link = LinkMessage::default();
        peer_link
            .attributes
            .push(LinkAttribute::IfName(peer.as_str().to_owned()));
        peer_link
            .attributes
            .push(LinkAttribute::NetNsFd(peer_ns.as_fd().as_raw_fd()));

        let mut request = LinkMessage::default();
        request
            .attributes
            .push(LinkAttribute::IfName(host.as_str().to_owned()));
        request.attributes.push(LinkAttribute::LinkInfo(vec![
            LinkInfo::Kind(InfoKind::Veth),
            LinkInfo::Data(InfoData::Veth(InfoVeth::Peer(peer_link))),
        ]));

        match self.ack(
            RouteNetlinkMessage::NewLink(request),
            NLM_F_CREATE | NLM_F_EXCL,
        ) {
            Ok(()) => {}
            Err(RequestError::Kernel(Errno::EEXIST)) => {
                return Err(LinkError::Exists(host.clone()))
            }
            Err(e) => return Err(e.into()),
        }

        self.link(host)?
            .ok_or_else(|| LinkError::Vanished(host.clone()))
    }

    /// Add `route`, failing if it already exists.
    pub fn add_route(&self, route: &Route) -> Result<(), RouteError> {
        match self.ack(
            RouteNetlinkMessage::NewRoute(route.rtnl_message()),
            NLM_F_CREATE | NLM_F_EXCL,
        ) {
            Ok(()) => Ok(()),
            Err(RequestError::Kernel(Errno::EEXIST)) => Err(RouteError::Exists(*route)),
            Err(e) => Err(RouteError::Request(*route, e)),
        }
    }

    /// Delete `route`; a missing route is `Ok`.
    pub fn delete_route(&self, route: &Route) -> Result<(), RouteError> {
        let mut message = route.rtnl_message();
        message.header.protocol = RouteProtocol::Unspec;
        message.header.scope = RouteScope::NoWhere;
        message.header.kind = RouteType::Unspec;

        match self.ack(RouteNetlinkMessage::DelRoute(message), 0) {
            Ok(()) | Err(RequestError::Kernel(Errno::ESRCH)) => Ok(()),
            Err(e) => Err(RouteError::Request(*route, e)),
        }
    }

    /// Send `message` and wait for the kernel to acknowledge it.
    pub fn ack(&self, message: RouteNetlinkMessage, flags: u16) -> Result<(), RequestError> {
        let reply = self.exchange(message, flags | NLM_F_ACK)?;

        match reply.payload {
            NetlinkPayload::Error(_) => Ok(()),
            _ => Err(RequestError::Unexpected(reply.header.message_type)),
        }
    }

    fn request(
        &self,
        message: RouteNetlinkMessage,
        flags: u16,
    ) -> Result<RouteNetlinkMessage, RequestError> {
        let reply = self.exchange(message, flags)?;

        match reply.payload {
            NetlinkPayload::InnerMessage(message) => Ok(message),
            _ => Err(RequestError::Unexpected(reply.header.message_type)),
        }
    }

    fn exchange(
        &self,
        message: RouteNetlinkMessage,
        flags: u16,
    ) -> Result<NetlinkMessage<RouteNetlinkMessage>, RequestError> {
        let mut packet = NetlinkMessage::from(message);
        packet.header.flags = NLM_F_REQUEST | flags;
        packet.finalize();

        let mut buf = vec![0; packet.buffer_len()];
        packet.serialize(&mut buf);
        self.0.send(&buf, 0).map_err(RequestError::Send)?;

        let (buf, _) = self.0.recv_from_full().map_err(RequestError::Recv)?;

        let reply = NetlinkMessage::<RouteNetlinkMessage>::deserialize(&buf)
            .map_err(RequestError::Decode)?;
        if let NetlinkPayload::Error(ErrorMessage {
            code: Some(code), ..
        }) = &reply.payload
        {
            return Err(RequestError::Kernel(Errno::from_raw(-code.get())));
        }

        Ok(reply)
    }
}

#[cfg(test)]
mod tests {
    use super::Rtnl;
    use crate::net::link::LinkError;
    use crate::net::netns::NetNs;
    use crate::net::route::{Route, RouteError};
    use crate::net::{IfIndex, IfName, Ipv4Net, Ipv6Net};
    use pretty_assertions::assert_eq;
    use rstest::rstest;
    use std::collections::BTreeMap;
    use std::fs;
    use std::net::{Ipv4Addr, Ipv6Addr};

    struct ScratchNs(Option<NetNs>);

    impl ScratchNs {
        fn new(test: &str) -> Option<Self> {
            if !nix::unistd::geteuid().is_root() {
                eprintln!("SKIP {test}: needs root to create a network namespace");
                return None;
            }
            let name = format!("hyper-test-{}-{test}", std::process::id());
            Some(Self(Some(
                NetNs::create(name.as_str().try_into().unwrap()).unwrap(),
            )))
        }

        fn get(&self) -> &NetNs {
            self.0.as_ref().expect("the namespace lives until drop")
        }
    }

    impl Drop for ScratchNs {
        fn drop(&mut self) {
            if let Some(ns) = self.0.take() {
                let _ = ns.remove();
            }
        }
    }

    #[rstest]
    fn every_interface_resolves_to_its_sysfs_ifindex() {
        let rtnl = Rtnl::open().unwrap();
        let sysfs: BTreeMap<String, u32> = fs::read_dir("/sys/class/net")
            .unwrap()
            .map(|entry| entry.unwrap())
            .filter(|entry| entry.path().join("ifindex").exists())
            .map(|entry| {
                let name = entry.file_name().into_string().unwrap();
                let index = fs::read_to_string(format!("/sys/class/net/{name}/ifindex"))
                    .unwrap()
                    .trim()
                    .parse()
                    .unwrap();
                (name, index)
            })
            .collect();
        let resolved: BTreeMap<String, u32> = sysfs
            .keys()
            .map(|name| {
                let link = rtnl.link(&name.parse().unwrap()).unwrap().unwrap();
                (name.clone(), link.index().get())
            })
            .collect();
        assert_eq!(resolved, sysfs);
    }

    #[rstest]
    fn a_missing_link_is_none() {
        let rtnl = Rtnl::open().unwrap();
        let link = rtnl.link(&"hyper-absent0".parse().unwrap()).unwrap();
        assert!(link.is_none());
    }

    #[rstest]
    fn the_veth_peer_lands_in_its_namespace_as_root() {
        let (Some(host), Some(peer)) = (ScratchNs::new("veth-host"), ScratchNs::new("veth-peer"))
        else {
            return;
        };
        let hv0: IfName = "hv0".parse().unwrap();
        let hp0: IfName = "hp0".parse().unwrap();
        let host_rtnl = host.get().rtnl().unwrap();
        let peer_rtnl = peer.get().rtnl().unwrap();

        host_rtnl.create_veth(&hv0, &hp0, peer.get()).unwrap();

        let present = |rtnl: &Rtnl, name: &IfName| rtnl.link(name).unwrap().is_some();
        assert_eq!(
            [
                present(&host_rtnl, &hv0),
                present(&host_rtnl, &hp0),
                present(&peer_rtnl, &hp0),
                present(&peer_rtnl, &hv0),
            ],
            [true, false, true, false]
        );
    }

    #[rstest]
    fn creating_an_existing_veth_is_exists_as_root() {
        let (Some(host), Some(peer)) = (
            ScratchNs::new("veth-dup-host"),
            ScratchNs::new("veth-dup-peer"),
        ) else {
            return;
        };
        let hv0: IfName = "hv0".parse().unwrap();
        let hp0: IfName = "hp0".parse().unwrap();
        let rtnl = host.get().rtnl().unwrap();

        rtnl.create_veth(&hv0, &hp0, peer.get()).unwrap();
        let again = rtnl.create_veth(&hv0, &hp0, peer.get());

        assert!(matches!(again, Err(LinkError::Exists(ref name)) if *name == hv0));
    }

    #[rstest]
    #[case::v4_on_link("route-v4", |dev| Route::V4 {
        dst: Ipv4Net { addr: Ipv4Addr::new(10, 9, 0, 0), prefix: 24.try_into().unwrap() },
        via: None,
        dev,
    })]
    #[case::v4_default_on_link("route-v4-default", |dev| Route::V4 {
        dst: Ipv4Net { addr: Ipv4Addr::UNSPECIFIED, prefix: 0.try_into().unwrap() },
        via: None,
        dev,
    })]
    #[case::v6_host_on_link("route-v6", |dev| Route::V6 {
        dst: Ipv6Net {
            addr: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 1, 0, 0, 5),
            prefix: 128.try_into().unwrap(),
        },
        via: None,
        dev,
    })]
    #[case::v6_default_via_link_local("route-v6-default", |dev| Route::V6 {
        dst: Ipv6Net { addr: Ipv6Addr::UNSPECIFIED, prefix: 0.try_into().unwrap() },
        via: Some(Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1)),
        dev,
    })]
    fn routes_add_once_and_delete_idempotently_as_root(
        #[case] test: &str,
        #[case] route: fn(IfIndex) -> Route,
    ) {
        let (Some(host), Some(peer)) = (
            ScratchNs::new(&format!("{test}-host")),
            ScratchNs::new(&format!("{test}-peer")),
        ) else {
            return;
        };
        let hv0: IfName = "hv0".parse().unwrap();
        let hp0: IfName = "hp0".parse().unwrap();
        let rtnl = host.get().rtnl().unwrap();
        let peer_rtnl = peer.get().rtnl().unwrap();
        let link = rtnl.create_veth(&hv0, &hp0, peer.get()).unwrap();
        link.set_up().unwrap();
        peer_rtnl.link(&hp0).unwrap().unwrap().set_up().unwrap();
        let route = route(link.index());

        rtnl.add_route(&route).unwrap();
        assert!(matches!(rtnl.add_route(&route), Err(RouteError::Exists(r)) if r == route));
        rtnl.delete_route(&route).unwrap();
        rtnl.delete_route(&route).unwrap();
        rtnl.add_route(&route).unwrap();
    }
}
