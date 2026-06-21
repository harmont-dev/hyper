defmodule Hyper.Firecracker.Api.CodecTest do
  use ExUnit.Case, async: true

  # Exercises the compile-time codec against REAL generated schemas (which carry
  # consolidated Jason.Encoder impls and generated decode/1). Fake test-defined
  # structs can't be used for the encode side: their defimpl is compiled after
  # protocol consolidation and would not be picked up.
  alias Hyper.Firecracker.Api.{CpuConfig, CpuidLeafModifier, Drive, RateLimiter, TokenBucket}

  describe "decode/1" do
    test "builds the struct and recurses nested schemas (drive -> rate_limiter -> bucket)" do
      data = %{
        "drive_id" => "rootfs",
        "is_root_device" => true,
        "is_read_only" => false,
        "rate_limiter" => %{"bandwidth" => %{"size" => 100, "refill_time" => 1000}}
      }

      assert %Drive{
               drive_id: "rootfs",
               is_root_device: true,
               is_read_only: false,
               rate_limiter: %RateLimiter{bandwidth: %TokenBucket{size: 100, refill_time: 1000}}
             } = Drive.decode(data)
    end

    test "recurses lists of primitives and lists of nested schemas" do
      cfg =
        CpuConfig.decode(%{
          "kvm_capabilities" => ["121", "!122"],
          "cpuid_modifiers" => [
            %{"leaf" => "0x0", "subleaf" => "0x0", "flags" => 1, "modifiers" => []}
          ]
        })

      assert cfg.kvm_capabilities == ["121", "!122"]

      assert [%CpuidLeafModifier{leaf: "0x0", subleaf: "0x0", flags: 1, modifiers: []}] =
               cfg.cpuid_modifiers
    end

    test "omits absent keys (stay at struct default) and maps nil through" do
      drive = Drive.decode(%{"drive_id" => "d", "is_root_device" => true})
      assert drive.drive_id == "d"
      assert drive.path_on_host == nil
      assert drive.rate_limiter == nil
      assert Drive.decode(nil) == nil
    end
  end

  describe "encode (Jason.Encoder)" do
    test "drops nil and :__info__ fields, keeps false, recurses nested structs" do
      drive = %Drive{
        drive_id: "d",
        is_root_device: false,
        rate_limiter: %RateLimiter{bandwidth: %TokenBucket{size: 1, refill_time: 2}}
      }

      assert Jason.decode!(Jason.encode!(drive)) == %{
               "drive_id" => "d",
               "is_root_device" => false,
               "rate_limiter" => %{"bandwidth" => %{"size" => 1, "refill_time" => 2}}
             }
    end
  end
end
