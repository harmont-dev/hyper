# Networking

This document serves to document and illustrate networking in Hyper. This
document assumes you are relatively familiar with high-level networking
concepts. I have done my best to provide useful links for new and unfamiliar
terms.

## VM Namespaces

Hyper allocates a single [network
namespace](https://man7.org/linux/man-pages/man7/network_namespaces.7.html) per
guest VM. The host has its own _host namespace_.

```mermaid
flowchart td
    subgraph host-netns
        subgraph if0
            ipv4["ipv4 108.61.202.54/23"]
            ipv6["ipv6 2001:19f0:5c00:19b9:5400:6ff:fe12:1a00/64"]
        end
    end

    subgraph vm1-netns
    end

    subgraph vm2-netns
    end
```

## Outgoing IPv4

For outgoing [IPv4](https://en.wikipedia.org/wiki/IPv4) traffic, Hyper
allocates a single
[NAT](https://en.wikipedia.org/wiki/Network_address_translation) per hypervisor
node.

## FAQ

This section aims to answer some commonly-asked questions.

### Why not reverse HTTP proxy?

One of my goals with Hyper is to be able to support arbitrary
protocols---`ssh`, `quic`, `tcp`, `udp` and pretty much anything on top of
[IP](https://en.wikipedia.org/wiki/Internet_Protocol). If Hyper used a reverse
HTTP proxy, we would only be able to support HTTP and websockets, which implies
all the aforemnetioned protocols would not be supported.
