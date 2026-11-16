defmodule Hyper.SuidHelper.WirePropertiesTest do
  @moduledoc """
  The node and the helper agree on the wire, checked against the real stamped helper binary
  (the one `Hyper.SuidHelper.Expected` was captured from), not a fixture.

  Laws:

    * every VM id `Hyper.Vm.Id.generate/0` mints is a VM id the helper parses, for both socket
      claims;
    * every firewall `Hyper.Vm.Firewall.new/2` accepts, up to `max_rules/0` in each direction
      and over the whole `1..65535` port space, becomes a `vm_firewall` request the helper
      parses;
    * a request the helper refuses to parse surfaces as `{:error, {2, "invalid request: ..."}}`,
      never as success or as another error.

  The helper runs unprivileged and not setuid here: a request it parses gets past the caller
  gate (the binary's group is the runner's) and then fails raising euid, before touching
  anything.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.SuidHelper
  alias Hyper.Vm.Firewall

  @helper "native/target/*-unknown-linux-musl/release/hyper-suidhelper"
          |> Path.wildcard()
          |> List.first()

  @moduletag skip: if(@helper, do: false, else: "no stamped helper; run mix compile")

  setup do
    previous = Application.get_env(:hyper, Hyper.Cfg.Tools, [])

    Application.put_env(
      :hyper,
      Hyper.Cfg.Tools,
      Keyword.put(previous, :suidhelper, Path.expand(@helper))
    )

    on_exit(fn -> Application.put_env(:hyper, Hyper.Cfg.Tools, previous) end)
  end

  defp parsed?({:error, {2, "invalid request" <> _}}), do: false
  defp parsed?({:error, {2, _message}}), do: true

  defp rule do
    gen all(
          protocol <- member_of([:tcp, :udp]),
          first <- one_of([constant(1), constant(65_535), integer(1..65_535)]),
          last <- one_of([constant(first), constant(65_535), integer(first..65_535)])
        ) do
      {protocol, first..last//1}
    end
  end

  defp rules do
    one_of([
      list_of(rule(), max_length: 8),
      list_of(rule(), length: Firewall.max_rules())
    ])
  end

  property "every minted VM id is one the helper parses" do
    check all(id <- repeatedly(&Hyper.Vm.Id.generate/0), max_runs: 25) do
      for claim <- [&SuidHelper.Vm.claim_api_socket/1, &SuidHelper.Vm.claim_vsock_socket/1] do
        result = claim.(id)
        assert parsed?(result), "#{id}: #{inspect(result)}"
      end
    end
  end

  property "every firewall the node accepts is one the helper parses" do
    check all(inbound <- rules(), outbound <- rules(), max_runs: 25) do
      {:ok, firewall} = Firewall.new(inbound, outbound)
      result = SuidHelper.Vm.firewall(Hyper.Vm.Id.generate(), firewall)
      assert parsed?(result), inspect(result)
    end
  end

  test "a request the helper cannot parse is an invalid-request error, not success" do
    for id <- ["v_1", "-v1", "", String.duplicate("a", 65), "v1/../x", "vé"] do
      assert {:error, {2, "invalid request" <> _}} = SuidHelper.Vm.claim_api_socket(id),
             inspect(id)
    end
  end
end
