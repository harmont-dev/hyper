# gRPC contract tests

Wire-level tests of `hyper.grpc.v0.Hyper` (see `proto/hyper/grpc/v0/hyper.proto`),
written in TypeScript so the server is exercised from a genuinely foreign client —
including wire shapes a BEAM client cannot produce (unknown enum ints).

Normally run via the `:integration` suite (`mix test --only integration`), which
boots the server and shells out here (see `test/e2e/grpc_contract_test.exs`).

Standalone, against any running Hyper node with gRPC enabled:

    npm ci
    HYPER_GRPC_ADDR=127.0.0.1:50051 npm test

`tests/lifecycle.test.ts` boots a real VM (set `HYPER_E2E_IMAGE` to override the
image); `tests/errors.test.ts` only needs a reachable server.
