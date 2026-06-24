# gRPC interface

Hyper's native API is BEAM-native (Elixir/Erlang processes calling `Hyper.*`).
The gRPC interface puts that same machine lifecycle behind a language-agnostic
contract, so consumers in **any** language -- and off-BEAM services -- can
create, stop, locate, and list microVMs.

> **v0 -- unstable.** The contract may change without notice during early
> development. Pin to a commit if you depend on it.

## Configuration

By default, the gRPC interface is **disabled**. You can enable it by editing
`config/runtime.exs` and setting:

```elixir
config :hyper, Hyper.Grpc.Config,
  enabled: true,
  port: 50051,
  cred: GRPC.Credential.new(
    ssl: [certfile: "/path/to/cert.pem", keyfile: "/path/to/key.pem"]
  )
```

Note that you can also disable secure mode and use plaintext gRPC:

```elixir
config :hyper, Hyper.Grpc.Config,
  enabled: true,
  port: 50051
```

> #### TLS Security {: .error}
>
> It is **strongly** advised you run gRPC with SSL enabled. Running
> `Hyper.Grpc` without SSL enabled in production could present a security risk
> and we strongly suggest against it.

## Client Usage

With `Hyper` running, you can create a new `gRPC` client in your favorite
language. We will be using _Python_ here:

```python
from google.protobuf import empty_pb2
from hyper.grpc.v0 import hyper_pb2, hyper_pb2_grpc

# Plaintext. For TLS, pass grpc.ssl_channel_credentials(ca_pem) to
# grpc.aio.secure_channel(...) instead.
client = hyper_pb2_grpc.HyperStub(grpc.aio.insecure_channel("localhost:50051"))
```

### Creating VMs

You can create new VMs with the `CreateVm` RPC.

```python
created = await client.CreateVm(
    hyper_pb2.CreateVmRequest(
        img_id="img-abc",
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

### Stopping a VM

You can stop a running VM with `StopVm`, which returns a
`google.protobuf.Empty`:

```python
await client.StopVm(hyper_pb2.StopVmRequest(vm_id=created.vm_id))
```

For full documentation, please read the documentation in the [`.proto`](TODO)
file.
