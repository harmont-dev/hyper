# gRPC interface

Hyper's native API is BEAM-native (Elixir/Erlang processes calling `Hyper.*`).
The gRPC interface puts that same machine lifecycle behind a language-agnostic
contract, so consumers in **any** language -- and off-BEAM services -- can
create, stop, locate, and list microVMs.

> **v0 -- unstable.** The contract may change without notice during early
> development. Pin to a commit if you depend on it.

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
from google.protobuf import empty_pb2
from hyper.grpc.v0 import hyper_pb2, hyper_pb2_grpc

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

### Listing VMs

You can list running virtual machines with `ListVms`, which takes a
`google.protobuf.Empty`:

```python
listed = await client.ListVms(empty_pb2.Empty())
for vm in listed.vms:
    print(vm.vm_id, vm.node)
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

You can stop a running VM with `StopVm`, which returns a
`google.protobuf.Empty`:

```python
await client.StopVm(hyper_pb2.StopVmRequest(vm_id=created.vm_id))
```

For full documentation, please read the documentation in the
[`.proto`](https://github.com/harmont-dev/hyper/blob/main/proto/hyper/grpc/v0/hyper.proto)
file.
