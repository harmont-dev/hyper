// Ad-hoc end-to-end driver: LoadImage -> CreateVm -> GetVm -> ListVms.
// Loader options mirror package.json's `gen` script (see src/client.ts).
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";

const here = path.dirname(fileURLToPath(import.meta.url));
const PROTO_ROOT = path.resolve(here, "../../proto");
const ADDR = process.env.HYPER_GRPC_ADDR ?? "127.0.0.1:50051";
const IMAGE = process.env.IMAGE_REF ?? "docker://docker.io/library/alpine:3.19";
const STEP = process.env.STEP ?? "all";

const def = protoLoader.loadSync("hyper/grpc/v0/hyper.proto", {
  longs: Number, enums: String, defaults: true, oneofs: true, includeDirs: [PROTO_ROOT],
});
const proto = grpc.loadPackageDefinition(def);
const client = new proto.hyper.grpc.v0.Hyper(ADDR, grpc.credentials.createInsecure());

const call = (m, req, timeoutMs) => new Promise((res, rej) => {
  const opts = { deadline: new Date(Date.now() + timeoutMs) };
  client[m](req, opts, (err, out) => (err ? rej(err) : res(out)));
});

const t0 = Date.now();
const el = () => `+${((Date.now() - t0) / 1000).toFixed(1)}s`;

try {
  if (STEP === "list") {
    console.log(el(), "ListVms ->", JSON.stringify(await call("ListVms", {}, 30_000)));
    process.exit(0);
  }
  console.log(el(), `LoadImage ${IMAGE} (pull+flatten, can take minutes)`);
  const loaded = await call("LoadImage", { imageRef: IMAGE }, 900_000);
  console.log(el(), "LoadImage ->", JSON.stringify(loaded));

  console.log(el(), "CreateVm ...");
  const vm = await call("CreateVm", {
    imgId: loaded.imgId,
    instanceType: "INSTANCE_TYPE_MICRO",
    arch: "ARCHITECTURE_X86_64",
  }, 300_000);
  console.log(el(), "CreateVm ->", JSON.stringify(vm));

  console.log(el(), "GetVm ->", JSON.stringify(await call("GetVm", { vmId: vm.vmId }, 30_000)));
  console.log(el(), "ListVms ->", JSON.stringify(await call("ListVms", {}, 30_000)));
  console.log(el(), "E2E OK: vm", vm.vmId, "booted on", vm.node);
} catch (e) {
  console.error(el(), "FAILED:", e.code, e.details ?? e.message);
  process.exit(1);
}
