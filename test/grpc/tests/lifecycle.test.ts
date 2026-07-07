import { expect, test } from "vitest";
import { status } from "@grpc/grpc-js";
import { call, connect, eventually, expectStatus, statusOf } from "../src/client";
import type { CreateVmResponse__Output } from "../generated/hyper/grpc/v0/CreateVmResponse";
import type { GetVmResponse__Output } from "../generated/hyper/grpc/v0/GetVmResponse";
import type { GetVmUsageResponse__Output } from "../generated/hyper/grpc/v0/GetVmUsageResponse";
import type { ListVmsResponse__Output } from "../generated/hyper/grpc/v0/ListVmsResponse";
import type { LoadImageResponse__Output } from "../generated/hyper/grpc/v0/LoadImageResponse";

const MIN = 60_000;

// public.ecr.aws mirrors library images without Docker Hub's per-IP pull
// limits (same image as test/e2e/vm_lifecycle_test.exs).
const IMAGE = process.env.HYPER_E2E_IMAGE ?? "public.ecr.aws/docker/library/alpine:3.19";

test(
  "LoadImage -> CreateVm -> GetVm -> ListVms -> GetVmUsage -> StopVm over the wire",
  { timeout: 20 * MIN },
  async () => {
    const client = connect();

    // LoadImage blocks through pull/unpack/build; the proto tells clients to
    // set a generous deadline.
    //
    // The generated client type carries both PascalCase and camelCase method
    // aliases (grpc-js's default), which defeats `call`'s inference of its
    // Res type parameter from the method overload set; the cast recovers the
    // response shape the wire actually returns.
    const loaded = (await call(client, client.loadImage, { imageRef: IMAGE }, 10 * MIN)) as LoadImageResponse__Output;
    expect(loaded.imgId).toBeTruthy();

    // A TERA instance (256 vCPU / 128 GiB) can never fit the test host:
    // the documented RESOURCE_EXHAUSTED contract, with a real image id so
    // capacity is the only thing being refused.
    await expectStatus(
      call(client, client.createVm, {
        imgId: loaded.imgId,
        instanceType: "INSTANCE_TYPE_TERA",
        arch: "ARCHITECTURE_X86_64",
      }),
      status.RESOURCE_EXHAUSTED,
    );

    // MICRO, matching vm_lifecycle_test.exs: the default CI node budget
    // refuses anything larger.
    const created = (await call(
      client,
      client.createVm,
      { imgId: loaded.imgId, instanceType: "INSTANCE_TYPE_MICRO", arch: "ARCHITECTURE_X86_64" },
      5 * MIN,
    )) as CreateVmResponse__Output;
    expect(created.vmId).toBeTruthy();
    expect(created.node).toBeTruthy();

    try {
      const located = (await call(client, client.getVm, { vmId: created.vmId })) as GetVmResponse__Output;
      expect(located.vmId).toBe(created.vmId);
      expect(located.node).toBe(created.node);

      const listed = (await call(client, client.listVms, {})) as ListVmsResponse__Output;
      expect((listed.vms ?? []).map((vm) => vm.vmId)).toContain(created.vmId);

      const usage = (await call(client, client.getVmUsage, { vmId: created.vmId })) as GetVmUsageResponse__Output;
      expect(usage.vmId).toBe(created.vmId);
      expect(usage.cpuUsec).toBeGreaterThanOrEqual(0);
    } finally {
      // A failed assertion must not leak a live VM into later tests.
      await call(client, client.stopVm, { vmId: created.vmId }, 2 * MIN);
    }

    const gone = await eventually(
      async () => (await statusOf(call(client, client.getVm, { vmId: created.vmId }))) === status.NOT_FOUND,
      90_000,
    );
    expect(gone, "stopped VM still resolvable via GetVm after 90s").toBe(true);
  },
);
