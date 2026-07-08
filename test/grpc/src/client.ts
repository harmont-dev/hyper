import * as path from "node:path";
import { fileURLToPath } from "node:url";
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import type { ProtoGrpcType } from "../generated/hyper";
import type { HyperClient } from "../generated/hyper/grpc/v0/Hyper";

const here = path.dirname(fileURLToPath(import.meta.url));
const PROTO_ROOT = path.resolve(here, "../../../proto");

// Options must mirror the `gen` script in package.json, or the generated
// types describe a different runtime shape than proto-loader produces.
const packageDefinition = protoLoader.loadSync("hyper/grpc/v0/hyper.proto", {
  longs: Number,
  enums: String,
  defaults: true,
  oneofs: true,
  includeDirs: [PROTO_ROOT],
});

const proto = grpc.loadPackageDefinition(packageDefinition) as unknown as ProtoGrpcType;

export type { HyperClient };

export const DEFAULT_ADDR = process.env.HYPER_GRPC_ADDR ?? "127.0.0.1:50061";

export function connect(addr: string = DEFAULT_ADDR): HyperClient {
  return new proto.hyper.grpc.v0.Hyper(addr, grpc.credentials.createInsecure());
}

type Unary<Req, Res> = (
  req: Req,
  options: grpc.CallOptions,
  callback: (err: grpc.ServiceError | null, res?: Res) => void,
) => unknown;

export function call<Req, Res>(
  client: HyperClient,
  method: Unary<Req, Res>,
  req: Req,
  deadlineMs = 30_000,
): Promise<Res> {
  const options: grpc.CallOptions = { deadline: new Date(Date.now() + deadlineMs) };
  return new Promise((resolve, reject) => {
    method.call(client, req, options, (err, res) => (err ? reject(err) : resolve(res as Res)));
  });
}

export async function statusOf(p: Promise<unknown>): Promise<grpc.status | null> {
  try {
    await p;
    return null;
  } catch (err) {
    return (err as grpc.ServiceError).code ?? grpc.status.UNKNOWN;
  }
}

export async function expectStatus(p: Promise<unknown>, want: grpc.status): Promise<void> {
  const got = await statusOf(p);
  if (got !== want) {
    const gotName = got === null ? "OK (call succeeded)" : grpc.status[got];
    throw new Error(`expected gRPC status ${grpc.status[want]}, got ${gotName}`);
  }
}

export async function eventually(
  fn: () => Promise<boolean>,
  deadlineMs: number,
  intervalMs = 500,
): Promise<boolean> {
  const deadline = Date.now() + deadlineMs;
  for (;;) {
    if (await fn()) return true;
    if (Date.now() > deadline) return false;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}
