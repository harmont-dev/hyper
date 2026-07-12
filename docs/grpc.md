# gRPC interface

Hyper's native API is BEAM-native (Elixir/Erlang processes calling `Hyper.*`).
The gRPC interface puts that same machine lifecycle behind a language-agnostic
contract, so consumers in **any** language -- and off-BEAM services -- can
create, stop, locate, and list microVMs.

> **v1 -- stable.** This is the first stable contract. Backward-compatible
> additions (new RPCs, new messages, appended fields, new enum values) may
> land in place; a breaking change would ship as a side-by-side `hyper.grpc.v2`
> package. Removed fields are retired with `reserved` and never reused.

> #### No authentication {: .warning}
>
> The gRPC API has **no authentication**. Any client that can reach the port can
> create and stop VMs and load images. It is **off by default** (`grpc.enabled =
> false`). When you enable it, bind it to loopback or a trusted network, or put
> it behind a proxy that terminates TLS and authenticates callers. TLS (`cred`)
> encrypts the channel but does not authenticate the client. Authentication is
> planned for a later release.

## Configuration

By default, the gRPC interface is **disabled**. The simplest way to enable it
is the `[grpc]` table of `/etc/hyper/config.toml`:

```toml
[grpc]
enabled = true
port = 50051
cred = { cert = "/path/to/cert.pem", key = "/path/to/key.pem" }
```

Alternatively, configure `Hyper.Cfg.Grpc` from Elixir — in the operator config
file `/etc/hyper/config.exs` (loaded at runtime), or in your own application's
`config/runtime.exs` when you embed Hyper as a dependency. Application env
takes precedence over the TOML table:

```elixir
config :hyper, Hyper.Cfg.Grpc,
  enabled: true,
  port: 50_051,
  cred: GRPC.Credential.new(
    ssl: [certfile: "/path/to/cert.pem", keyfile: "/path/to/key.pem"]
  )
```

Omit `cred` to serve plaintext gRPC.

> #### No authentication {: .error}
>
> The gRPC API currently has **no authentication or authorization**: any
> client that can reach the port has full VM lifecycle control (create, stop,
> load images). TLS (`cred`) encrypts the transport but does **not**
> authenticate callers. Only enable the interface on a network you trust —
> bind it to a private interface or firewall the port so that just your own
> services can reach it.

## Client Usage

With `Hyper` running, you can create a new `gRPC` client in your favorite
language. We will be using _Python_ here:

```python
import grpc
from hyper.grpc.v1 import hyper_pb2, hyper_pb2_grpc

# Plaintext. For TLS, pass grpc.ssl_channel_credentials(ca_pem) to
# grpc.aio.secure_channel(...) instead.
client = hyper_pb2_grpc.HyperStub(grpc.aio.insecure_channel("localhost:50051"))
```

### Loading Images

Before you can create a VM you need an image in the cluster. `LoadImage` pulls an
OCI image, builds its rootfs, and records it -- returning the `img_id` you pass to
`CreateVm`. It blocks until the load finishes (this can take minutes), so set a
generous deadline.

```python
loaded = await client.LoadImage(
    hyper_pb2.LoadImageRequest(
        image_ref="docker.io/library/alpine:3.19",
        # label is optional; defaults to image_ref.
    )
)
print(loaded.img_id)  # pass this to CreateVm
```

### Creating VMs

You can create new VMs with the `CreateVm` RPC.

```python
created = await client.CreateVm(
    hyper_pb2.CreateVmRequest(
        img_id=loaded.img_id,
        instance_type=hyper_pb2.INSTANCE_TYPE_DECI,
        arch=hyper_pb2.ARCHITECTURE_X86_64,
        # boot_args is optional; omit it for the default kernel cmdline.
    )
)
print(created.vm_id, created.node)
```

`instance_type` and `arch` are **required**. Their proto3 zero value is the
`*_UNSPECIFIED` sentinel; sending it (or omitting the field) returns
`INVALID_ARGUMENT`. Always set them explicitly, e.g.
`hyper_pb2.INSTANCE_TYPE_CENTI`, `hyper_pb2.ARCHITECTURE_X86_64`.

### Listing VMs

You can list running virtual machines with `ListVms`, which is paginated via
`page_size`/`page_token` in and `next_page_token` out:

```python
from hyper.grpc.v1 import hyper_pb2

# List a page of VMs. Follow next_page_token until it is empty for the full set.
listed = await client.ListVms(hyper_pb2.ListVmsRequest(page_size=100))
for vm in listed.vms:
    print(vm.vm_id, vm.node)
next_token = listed.next_page_token  # "" means this was the last page
```

### Getting VM Info

You can query a VM with `GetVm`, which returns the node it runs on:

```python
info = await client.GetVm(hyper_pb2.GetVmRequest(vm_id=created.vm_id))
print(info.vm_id, info.node)
```

### Reading VM Usage

You can read a VM's metered compute with `GetVmUsage`. It reports the
cumulative CPU time the VM has *actually executed* — measured from its
cgroup, so an idle VM accrues (almost) nothing. This is the counter to bill
on: compute performed, not compute allocated. Stopped VMs report their
recorded lifetime total. A VM that never accrued any compute (for example,
created and stopped while fully idle) has no recorded usage and returns
`NOT_FOUND`.

```python
usage = await client.GetVmUsage(hyper_pb2.GetVmUsageRequest(vm_id=created.vm_id))
print(f"{usage.vm_id} consumed {usage.cpu_usec / 1e6:.2f} CPU-seconds")
```

Under the hood, usage is persisted once a minute as append-only windows in
the `vm_usage` Postgres table (`vm_id`, `window_start`, `window_end`,
`cpu_usec`), so billing pipelines can also aggregate ranges with SQL directly.

### Stopping a VM

You can stop a running VM with `StopVm`, which takes a request and returns an
(empty) `StopVmResponse`:

```python
await client.StopVm(hyper_pb2.StopVmRequest(vm_id=created.vm_id))  # -> StopVmResponse
```

For full documentation, please read the documentation in the
[`.proto`](https://github.com/harmont-dev/hyper/blob/main/proto/hyper/grpc/v1/hyper.proto)
file.
