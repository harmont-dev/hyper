defmodule Hyper.Node.FireVMM.Net do
  @moduledoc "Firecracker network configuration for a particular VM."

  alias Hyper.Firecracker.Api.{NetworkInterface, RateLimiter, TokenBucket}
  alias Hyper.Node.Net.Ip
  alias Unit.Bandwidth
  alias Unit.Time

  @iface "eth0"
  @tap "tap0"

  # Firecracker refills a bucket of `size` bytes every `refill_time`; a one-second
  # refill makes the bucket hold exactly one second of the instance's bandwidth.
  @refill Time.s(1)

  @doc "MAC for `vm_id`."
  @spec guest_mac(Hyper.Vm.Id.t()) :: String.t()
  def guest_mac(vm_id) do
    # Six octets: the fixed locally-administered-unicast leading byte plus five
    # from the id hash. Firecracker rejects anything but a full XX:XX:XX:XX:XX:XX
    # MAC (a five-octet address 400s the NIC config and the VM never boots).
    <<_::8, b1, b2, b3, b4, b5, _::binary>> = :crypto.hash(:sha256, vm_id)

    [0x02, b1, b2, b3, b4, b5]
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> String.downcase()
  end

  @doc "The Firecracker NIC spec (guest `eth0` bound to in-netns `tap0`), capped at `net_bw` each way."
  @spec interface(Hyper.Vm.Id.t(), Bandwidth.t()) :: NetworkInterface.t()
  def interface(vm_id, net_bw) do
    %NetworkInterface{
      iface_id: @iface,
      host_dev_name: @tap,
      guest_mac: guest_mac(vm_id),
      rx_rate_limiter: rate_limiter(net_bw),
      tx_rate_limiter: rate_limiter(net_bw)
    }
  end

  @spec rate_limiter(Bandwidth.t()) :: RateLimiter.t()
  defp rate_limiter(net_bw) do
    %RateLimiter{
      bandwidth: %TokenBucket{
        size: Bandwidth.as_bytes_per_sec(net_bw) * Time.as_s(@refill),
        refill_time: Time.as_ms(@refill)
      }
    }
  end

  @doc "Kernel cmdline fragments."
  @spec cmdline(Ip.Lease.t()) :: String.t()
  def cmdline(%Ip.Lease{} = lease), do: lease |> Ip.guest_args() |> Enum.join(" ")
end
