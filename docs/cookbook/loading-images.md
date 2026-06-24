# Loading images

Before you can boot a VM you need an image in Hyper's database and its rootfs
blob in the shared media store (`layer_dir`). `Hyper.Img.OciLoader` does both
from a single OCI reference.

## Prerequisites

The host running the loader needs three tools on `PATH` (override the paths via
`config :hyper, skopeo_path:/umoci_path:/mke2fs_path:` if they live elsewhere):

- `skopeo` -- pulls the image, applying manifest-list arch selection.
- `umoci` -- flattens the OCI layers into a rootfs (handles whiteouts).
- `mke2fs` (e2fsprogs) -- builds the ext4 rootfs image, rootless.

Postgres must be running with migrations applied (`mix ecto.migrate`), and
`layer_dir` must be writable.

## Load an image

```elixir
{:ok, img_id} = Hyper.Img.OciLoader.load("docker.io/library/alpine:3.19")
```

The loader pulls the image for this node's architecture, flattens it, builds
`layer_<sha256>.img` in `layer_dir`, and records a one-layer base image. The
returned `img_id` is the content hash; pass it to `Hyper.create_vm/1`.

Re-running `load/1` for the same reference rebuilds the rootfs; because ext4
images are not byte-reproducible, you may get a fresh `img_id` each time.

## Booting it

The loader produces a *faithful* rootfs -- it does not add an init. A container
image's entrypoint is not an init, so you must tell the kernel what to run. Pass
`boot_args` to `create_vm` (the root drive is `/dev/vda`):

```elixir
{:ok, vm} =
  Hyper.create_vm(%Hyper.Vm.Spec{
    img_id: img_id,
    boot_args: "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw init=/bin/sh"
  })
```

> The default `boot_args` (`console=ttyS0 reboot=k panic=1 pci=off`) omit
> `root=` and `init=`, so an OCI-derived rootfs will not boot without the
> additions above.
