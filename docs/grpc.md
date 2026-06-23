# gRPC interface

Hyper's native API is BEAM-native (Elixir/Erlang processes calling `Hyper.*`).
The gRPC interface puts that same machine lifecycle behind a language-agnostic
contract, so consumers in **any** language — and off-BEAM services — can create,
stop, locate, and list microVMs.

> **v0 — unstable.** The contract may change without notice during early
> development. Pin to a commit if you depend on it.

## The contract

The service is `hyper.grpc.v0.Machines`, defined in
[`proto/hyper/grpc/v0/hyper.proto`](../proto/hyper/grpc/v0/hyper.proto):

| RPC            | Purpose                                            | Errors |
| -------------- | -------------------------------------------------- | ------ |
| `CreateMachine`| Boot a microVM from an image; returns its `vm_id`. | `INVALID_ARGUMENT` (bad/missing image or enum), `RESOURCE_EXHAUSTED` (no capacity), `UNAVAILABLE` (host lost mid-create) |
| `StopMachine`  | Tear down a running microVM.                       | `NOT_FOUND` (unknown id), `UNAVAILABLE` (host down) |
| `GetMachine`   | Which node a microVM runs on.                      | `NOT_FOUND` |
| `ListMachines` | Every microVM known to the cluster.                | — |

A machine is addressed by its **`vm_id`** — a URL-safe base64 string the server
mints at creation. The server is stateless and identical on every node;
placement and routing are cluster-wide, so any node can serve any request.

### Optional fields

`CreateMachineRequest` uses proto3 `optional` (explicit field presence) instead
of magic sentinel enum values. An **unset** field is absent on the wire (and
`nil` in Elixir), and the server applies its default:

| Field           | Type           | Unset means                          |
| --------------- | -------------- | ------------------------------------ |
| `img_id`        | `string`       | required                             |
| `instance_type` | `InstanceType` | `INSTANCE_TYPE_BASE`                 |
| `arch`          | `Architecture` | resolve to the scheduling node's arch|
| `boot_args`     | `string`       | the standard serial-console cmdline  |

There is no `*_UNSPECIFIED` member: leave the field out to get the default.

## Configuring the server

The server is **off by default**. Enable and configure it from your own
application config under `config :hyper, Hyper.Grpc`. Only `:enabled` is special
— every other key is passed straight through to
[`GRPC.Server.Supervisor`](https://hexdocs.pm/grpc_server/GRPC.Server.Supervisor.html),
so you control the listener entirely (`Hyper.Grpc.Config` documents this).

### Plaintext (development)

```elixir
# config/dev.exs
config :hyper, Hyper.Grpc,
  enabled: true,
  port: 50_051
```

`:port` defaults to `50051` if omitted.

### TLS (production)

Build the credential where you load your keys. Use `config/runtime.exs` so cert
paths are read at boot, not compile time:

```elixir
# config/runtime.exs
if config_env() == :prod do
  config :hyper, Hyper.Grpc,
    enabled: true,
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

Hyper never reads the filesystem on your behalf — load secrets from env, a
vault, or anywhere else, and hand the supervisor a finished `:cred`. Any other
supervisor option works too (`adapter_opts:`, `max_body_size:`, …).

### How it starts

`Hyper.Application` splices `Hyper.Grpc.server_children/0` into its supervision
tree. That returns `[]` when `enabled: false`, so a default build starts no
server. Run the server on as many nodes as you like.

## Connecting

### From any language

Generate a client stub from `proto/hyper/grpc/v0/hyper.proto` with your
language's gRPC tooling (`protoc`, `buf`, etc.) and call the `Machines` service.
The `.proto` ships in the published package as well as the repo.

### From the BEAM

Use the generated stub with the `connect/2` helper (which defaults to the Mint
adapter):

```elixir
# Plaintext
{:ok, ch} = Hyper.Grpc.connect("localhost:50051")

# TLS, verifying the server against a CA bundle
{:ok, ch} = Hyper.Grpc.connect("hyper.example.com:50051", ca: "/etc/hyper/ca.pem")

{:ok, %Hyper.Grpc.V0.CreateMachineResponse{vm_id: vm_id, node: node}} =
  Hyper.Grpc.V0.Machines.Stub.create_machine(
    ch,
    %Hyper.Grpc.V0.CreateMachineRequest{
      img_id: "img-abc",
      instance_type: :INSTANCE_TYPE_DECI
    }
  )

{:ok, _} =
  Hyper.Grpc.V0.Machines.Stub.stop_machine(
    ch,
    %Hyper.Grpc.V0.StopMachineRequest{vm_id: vm_id}
  )
```

## Regenerating the bindings

The Elixir bindings (`lib/hyper/grpc/v0/hyper.pb.ex`) are **not committed** —
they are generated from the `.proto` by the `:grpc_gen` Mix compiler before the
Elixir compiler runs, the same way the Firecracker bindings are. Editing the
`.proto` and recompiling is enough; to force a regen run `mix grpc.gen`.

This requires `protoc` and the `protoc-gen-elixir` plugin in any environment
that compiles Hyper from a fresh tree:

```sh
sudo apt-get install -y protobuf-compiler   # or: brew install protobuf
mix escript.install hex protobuf 0.17.0     # provides protoc-gen-elixir
```

The plugin escript installs to `~/.mix/escripts`, which the compiler prepends to
`PATH` automatically.
