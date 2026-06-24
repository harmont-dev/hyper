# gRPC interface

Hyper's native API is BEAM-native (Elixir/Erlang processes calling `Hyper.*`).
The gRPC interface puts that same machine lifecycle behind a language-agnostic
contract, so consumers in **any** language -- and off-BEAM services -- can
create, stop, locate, and list microVMs.

> **v0 -- unstable.** The contract may change without notice during early
> development. Pin to a commit if you depend on it.

## VMs

With `Hyper` running, you can create a new `gRPC` client:

```python
import asyncio
import grpc
from google.protobuf import empty_pb2
from hyper.grpc.v0 import hyper_pb2, hyper_pb2_grpc

# Plaintext. For TLS, pass grpc.ssl_channel_credentials(ca_pem) to
# grpc.aio.secure_channel(...) instead.
channel = grpc.aio.insecure_channel("localhost:50051")
client = hyper_pb2_grpc.HyperStub(channel)
```

The RPC calls below are awaited, so they run inside an `async def` (e.g. driven
by `asyncio.run(main())`).

### Creating VMs

You can create new VMs with the `CreateVm` RPC. `instance_type` and `arch` are
required by the contract; set them explicitly (an unset enum field decodes to
its zero value):

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

You can query a VM with `GetVm`, which returns the node it runs on (and raises
`NOT_FOUND` if the id is unknown):

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


## Configuring the server

The server **always runs** -- it is a core interface, not an opt-in add-on, and
an idle listener costs next to nothing. With no config it serves plaintext on
port `50051`. Tune the listener from your own application config under
`config :hyper, Hyper.Grpc`; every key is passed straight through to
[`GRPC.Server.Supervisor`](https://hexdocs.pm/grpc_server/GRPC.Server.Supervisor.html),
so you control it entirely (`Hyper.Grpc.Config` documents this).

### Plaintext (development)

```elixir
# config/dev.exs
config :hyper, Hyper.Grpc, port: 50_051
```

`:port` defaults to `50051` if omitted.

### TLS (production)

Build the credential where you load your keys. Use `config/runtime.exs` so cert
paths are read at boot, not compile time:

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :hyper, Hyper.Grpc,
    port: 50_051,
    cred:
      GRPC.Credential.new(
        ssl: [
          certfile: System.fetch_env!("HYPER_GRPC_TLS_CERT"),
          keyfile: System.fetch_env!("HYPER_GRPC_TLS_KEY")
        ]
      )
end
```

Hyper never reads the filesystem on your behalf -- load secrets from env, a
vault, or anywhere else, and hand the supervisor a finished `:cred`. Any other
supervisor option works too (`adapter_opts:`, `max_body_size:`, ...).

### How it starts

`Hyper.Application` unconditionally splices `Hyper.Grpc.server_children/0` into
its supervision tree on every node. Because each node binds `:port`, running
several nodes on one host (e.g. a local cluster) means giving each its own port
in config.

## Connecting

### From any language

Generate a client stub from `proto/hyper/grpc/v0/hyper.proto` with your
language's gRPC tooling (`protoc`, `buf`, etc.) and call the `Hyper` service.
The `.proto` ships in the published package as well as the repo.

### From the BEAM

Use the generated stub with the `connect/2` helper (which defaults to the Mint
adapter):

```elixir
# Plaintext
{:ok, ch} = Hyper.Grpc.connect("localhost:50051")

# TLS, verifying the server against a CA bundle
{:ok, ch} = Hyper.Grpc.connect("hyper.example.com:50051", ca: "/etc/hyper/ca.pem")

{:ok, %Hyper.Grpc.V0.CreateVmResponse{vm_id: vm_id, node: node}} =
  Hyper.Grpc.V0.Hyper.Stub.create_vm(
    ch,
    %Hyper.Grpc.V0.CreateVmRequest{
      img_id: "img-abc",
      instance_type: :INSTANCE_TYPE_DECI
    }
  )

{:ok, _} =
  Hyper.Grpc.V0.Hyper.Stub.stop_vm(
    ch,
    %Hyper.Grpc.V0.StopVmRequest{vm_id: vm_id}
  )
```
