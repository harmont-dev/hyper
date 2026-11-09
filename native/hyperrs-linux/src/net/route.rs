// SPDX-License-Identifier: MIT
//! Routes in the kernel's main routing table.

use super::{IfIndex, Ipv4Net, Ipv6Net, RequestError};
use netlink_packet_route::route::{
    RouteAddress, RouteAttribute, RouteHeader, RouteMessage, RouteProtocol, RouteScope, RouteType,
};
use netlink_packet_route::AddressFamily;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use thiserror::Error as ThisError;

/// A route to `dst` out of `dev`, through gateway `via` or directly on the link.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Route {
    V4 {
        dst: Ipv4Net,
        via: Option<Ipv4Addr>,
        dev: IfIndex,
    },
    V6 {
        dst: Ipv6Net,
        via: Option<Ipv6Addr>,
        dev: IfIndex,
    },
}

#[derive(Debug, ThisError)]
pub enum RouteError {
    #[error("route {0:?} already exists")]
    Exists(Route),
    #[error("route {0:?}: {1}")]
    Request(Route, #[source] RequestError),
}

impl Route {
    /// The rtnetlink message describing this route.
    pub fn rtnl_message(&self) -> RouteMessage {
        let (family, dst, dst_len, via, dev) = match *self {
            Self::V4 { dst, via, dev } => (
                AddressFamily::Inet,
                IpAddr::V4(dst.addr),
                dst.prefix.get(),
                via.map(IpAddr::V4),
                dev,
            ),
            Self::V6 { dst, via, dev } => (
                AddressFamily::Inet6,
                IpAddr::V6(dst.addr),
                dst.prefix.get(),
                via.map(IpAddr::V6),
                dev,
            ),
        };

        let mut message = RouteMessage::default();
        message.header.address_family = family;
        message.header.destination_prefix_length = dst_len;
        message.header.table = RouteHeader::RT_TABLE_MAIN;
        message.header.protocol = RouteProtocol::Boot;
        message.header.kind = RouteType::Unicast;
        message.header.scope = match via {
            Some(_) => RouteScope::Universe,
            None => RouteScope::Link,
        };
        message
            .attributes
            .push(RouteAttribute::Destination(RouteAddress::from(dst)));
        if let Some(via) = via {
            message
                .attributes
                .push(RouteAttribute::Gateway(RouteAddress::from(via)));
        }
        message.attributes.push(RouteAttribute::Oif(dev.get()));
        message
    }
}
