defmodule Hyper.Node.FireVMM.Client.BodyTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Client.Body
  alias Hyper.Node.FireVMM.Client.Schema.{BootSource, Drive, RateLimiter, TokenBucket}

  test "drops nil fields" do
    assert Body.encode(%BootSource{kernel_image_path: "/k"}) == %{kernel_image_path: "/k"}
  end

  test "keeps false and zero values" do
    drive = %Drive{drive_id: "rootfs", is_root_device: true, is_read_only: false}
    assert Body.encode(drive) == %{drive_id: "rootfs", is_root_device: true, is_read_only: false}
  end

  test "recurses into nested structs" do
    drive = %Drive{
      drive_id: "d",
      is_root_device: false,
      rate_limiter: %RateLimiter{bandwidth: %TokenBucket{size: 100, refill_time: 1000}}
    }

    assert Body.encode(drive) == %{
             drive_id: "d",
             is_root_device: false,
             rate_limiter: %{bandwidth: %{size: 100, refill_time: 1000}}
           }
  end

  test "recurses into lists of structs" do
    assert Body.encode(%{xs: [%TokenBucket{size: 1, refill_time: 2}]}) ==
             %{xs: [%{size: 1, refill_time: 2}]}
  end

  test "passes through a plain map (arbitrary MMDS contents)" do
    assert Body.encode(%{"foo" => %{"bar" => 1}}) == %{"foo" => %{"bar" => 1}}
  end
end
