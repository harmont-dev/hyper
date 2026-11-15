defmodule Hyper.Grpc.CodecWirePropertiesTest do
  @moduledoc """
  The v1 wire contract (`proto/hyper/grpc/v1/hyper.proto`) as seen through
  `Hyper.Grpc.Codec`, driven from protobuf-encoded bytes so enum values the
  generated module does not know arrive as bare integers, exactly as an older
  or newer client would send them.

    * every `CreateVmRequest` decodes or is refused with the specific
      INVALID_ARGUMENT reason — `*_UNSPECIFIED` is "missing", any other
      unknown integer is "bad" — and never crashes the codec;
    * the instance-type and architecture enums map one-to-one onto the
      domain: every domain instance type is reachable from exactly one wire
      value, and both architectures likewise;
    * a `PortRule` is accepted exactly when its protocol is TCP or UDP and
      `1 <= first_port <= last_port <= 65535`; an accepted firewall renders
      back to the same `[first, last]` pairs, in order;
    * `boot_args` of up to 1024 printable bytes are kept, 1025 are refused, and
      appending a reserved argument (`--`, `ip=`, `nfsaddrs=`, `hyper.*`) to
      any accepted cmdline makes it refused;
    * any error reason the codec does not recognise maps to INTERNAL with a
      fixed message, so internal detail never reaches the client;
    * an unset firewall applies the documented default: nothing open inbound,
      nothing blocked outbound.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Grpc.Codec
  alias Hyper.Grpc.V1.{CreateVmRequest, PortRule}
  alias Hyper.Grpc.V1.Firewall, as: FirewallPb
  alias Hyper.Vm.{Firewall, Instance, Spec}

  @moduletag :capture_log

  @instance_wire 1..11
  @arch_wire 1..2

  defp over_the_wire(%CreateVmRequest{} = req),
    do: req |> CreateVmRequest.encode() |> CreateVmRequest.decode()

  defp request(fields), do: struct!(CreateVmRequest, Keyword.merge([img_id: "img"], fields))

  property "every instance_type/arch integer decodes or is refused with its specific reason" do
    check all(type <- integer(0..40), arch <- integer(0..8)) do
      result = Codec.from_grpc(over_the_wire(request(instance_type: type, arch: arch)))

      expected =
        cond do
          type == 0 -> {:error, :missing_instance_type}
          type not in @instance_wire -> {:error, :bad_instance_type}
          arch == 0 -> {:error, :missing_arch}
          arch not in @arch_wire -> {:error, :bad_arch}
          true -> :ok
        end

      case expected do
        :ok -> assert {:ok, %Spec{img_id: "img"}} = result
        refusal -> assert result == refusal
      end
    end
  end

  test "the instance and architecture enums map one-to-one onto the domain" do
    decode = fn type, arch ->
      {:ok, spec} = Codec.from_grpc(over_the_wire(request(instance_type: type, arch: arch)))
      spec
    end

    types = Enum.map(@instance_wire, &decode.(&1, 1).type)
    arches = Enum.map(@arch_wire, &decode.(1, &1).arch)

    assert Enum.sort(types) == Enum.sort(Instance.types())
    assert Enum.sort(arches) == [:aarch64, :x86_64]
  end

  defp port do
    frequency([
      {3, member_of([0, 1, 2, 1023, 65_534, 65_535, 65_536, 70_000, 4_294_967_295])},
      {5, integer(0..70_000)}
    ])
  end

  defp port_rule do
    gen all(protocol <- integer(0..4), first <- port(), last <- port()) do
      %PortRule{protocol: protocol, first_port: first, last_port: last}
    end
  end

  defp valid_rule?(%PortRule{protocol: p, first_port: f, last_port: l}),
    do: p in 1..2 and f >= 1 and f <= l and l <= 65_535

  property "a port rule is accepted exactly when its protocol and ascending range are valid" do
    check all(
            inbound <- list_of(port_rule(), max_length: 4),
            outbound <- list_of(port_rule(), max_length: 4)
          ) do
      req =
        request(
          instance_type: 1,
          arch: 1,
          firewall: %FirewallPb{inbound: inbound, outbound_blocked: outbound}
        )

      result = Codec.from_grpc(over_the_wire(req))

      if Enum.all?(inbound ++ outbound, &valid_rule?/1) do
        assert {:ok, %Spec{firewall: firewall}} = result
        rendered = Firewall.to_request(firewall)
        assert Enum.map(rendered.inbound, & &1.ports) == pairs(inbound)
        assert Enum.map(rendered.outbound_blocked, & &1.ports) == pairs(outbound)

        assert Enum.map(rendered.inbound, & &1.protocol) == protocols(inbound)
        assert Enum.map(rendered.outbound_blocked, & &1.protocol) == protocols(outbound)
      else
        assert {:error, {:bad_firewall_rule, _}} = result
      end
    end
  end

  test "a direction of 128 rules is accepted and 129 is refused" do
    rule = %PortRule{protocol: 1, first_port: 80, last_port: 80}

    for {count, expected} <- [{128, :ok}, {129, :too_many_firewall_rules}] do
      for direction <- [:inbound, :outbound_blocked] do
        firewall = struct!(FirewallPb, [{direction, List.duplicate(rule, count)}])
        req = request(instance_type: 1, arch: 1, firewall: firewall)

        case {expected, Codec.from_grpc(over_the_wire(req))} do
          {:ok, result} -> assert {:ok, %Spec{}} = result
          {reason, result} -> assert result == {:error, reason}, "#{count} #{direction}"
        end
      end
    end
  end

  defp pairs(rules), do: Enum.map(rules, &[&1.first_port, &1.last_port])

  defp protocols(rules), do: Enum.map(rules, &Enum.at(["", "tcp", "udp"], &1.protocol))

  defp boot_arg do
    string(Enum.concat([?a..?z, ?0..?9, [?=, ?., ?,, ?_, ?-, ?/]]), min_length: 1, max_length: 12)
    |> filter(&(not reserved?(&1)))
  end

  defp reserved?(arg),
    do: arg == "--" or String.starts_with?(arg, ["ip=", "nfsaddrs=", "hyper."])

  defp boot_args(args) do
    Codec.from_grpc(over_the_wire(request(instance_type: 1, arch: 1, boot_args: args)))
  end

  property "appending a reserved argument to any accepted cmdline makes it refused" do
    check all(
            args <- list_of(boot_arg(), min_length: 1, max_length: 8),
            reserved <-
              member_of(["--", "ip=dhcp", "nfsaddrs=1.2.3.4", "hyper.vm_id=x", "hyper."])
          ) do
      cmdline = Enum.join(args, " ")
      assert {:ok, %Spec{boot_args: ^cmdline}} = boot_args(cmdline)
      assert boot_args(cmdline <> " " <> reserved) == {:error, :bad_boot_args}
      assert boot_args(reserved <> " " <> cmdline) == {:error, :bad_boot_args}
    end
  end

  property "a cmdline carrying any byte outside printable ASCII, or a quote, is refused" do
    check all(
            args <- list_of(boot_arg(), min_length: 1, max_length: 4),
            bad <- one_of([integer(0..0x1F), constant(0x22), integer(0x7F..0xFF)]),
            at <- integer(0..100)
          ) do
      cmdline = Enum.join(args, " ")
      cut = rem(at, byte_size(cmdline) + 1)
      <<head::binary-size(^cut), tail::binary>> = cmdline
      poisoned = head <> <<bad>> <> tail

      req =
        request(
          instance_type: :INSTANCE_TYPE_MICRO,
          arch: :ARCHITECTURE_X86_64,
          boot_args: poisoned
        )

      result = Codec.from_grpc(req)

      assert result == {:error, :bad_boot_args}
    end
  end

  test "boot_args are capped at exactly 1024 bytes" do
    at_cap = String.duplicate("a", 1024)
    assert {:ok, %Spec{boot_args: ^at_cap}} = boot_args(at_cap)
    assert boot_args(at_cap <> "a") == {:error, :bad_boot_args}
  end

  defp unrecognised_reason do
    one_of([
      atom(:alphanumeric) |> filter(&(not known_reason?(&1))),
      tuple({atom(:alphanumeric), string(:printable)}),
      string(:printable),
      integer()
    ])
  end

  defp known_reason?(reason) do
    reason in [
      :missing_img_id,
      :missing_instance_type,
      :missing_arch,
      :bad_page_token,
      :bad_instance_type,
      :bad_arch,
      :missing_firewall,
      :too_many_firewall_rules,
      :bad_boot_args,
      :not_found,
      :unknown_image,
      :stopping,
      :not_ready,
      :machine_unreachable,
      :node_unreachable,
      :no_capacity,
      :exhausted,
      :missing_image_ref,
      :invalid_ref
    ]
  end

  property "an unrecognised error reason is INTERNAL with a fixed message" do
    internal = GRPC.Status.internal()

    check all(reason <- unrecognised_reason()) do
      assert %GRPC.RPCError{status: ^internal, message: "internal error"} =
               Codec.to_grpc({:error, reason})
    end
  end

  test "an unset firewall opens nothing inbound and blocks nothing outbound, as v1 documents" do
    assert {:ok, %Spec{firewall: firewall}} =
             Codec.from_grpc(over_the_wire(request(instance_type: 1, arch: 1)))

    assert firewall == %Firewall{inbound: [], outbound_blocked: []}
  end
end
