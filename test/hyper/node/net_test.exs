defmodule Hyper.Node.NetTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.Net
  alias Hyper.Node.Net.Ip.Host

  @host %Host{
    uplink: "if0",
    transit_prefix: {{10, 200, 0, 0}, 26},
    vm_prefix: {{0x2001, 0xDB8, 0, 0, 1, 0, 0, 0}, 80}
  }

  setup do
    start_supervised!({Net, @host})
    :ok
  end

  test "every NetId is handed out once before the pool is exhausted" do
    claimed = for _ <- 1..16, do: elem(Net.claim(), 1)

    assert Enum.sort(claimed) == Enum.to_list(0..15)
    assert Net.claim() == {:error, :exhausted}
  end

  test "a released NetId is handed out again" do
    exhaust()
    Net.release(3)

    assert Net.claim() == {:ok, 3}
  end

  test "a NetId bound to an owner is handed out again once the owner dies" do
    exhaust()
    owner = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Net.bind(5, owner)
    Process.exit(owner, :kill)

    assert await_claim() == {:ok, 5}
  end

  defp exhaust do
    for _ <- 1..16, do: {:ok, _} = Net.claim()
    {:error, :exhausted} = Net.claim()
  end

  defp await_claim(tries \\ 200)
  defp await_claim(0), do: flunk("the dead owner's NetId never returned to the pool")

  defp await_claim(tries) do
    case Net.claim() do
      {:error, :exhausted} ->
        Process.sleep(5)
        await_claim(tries - 1)

      claimed ->
        claimed
    end
  end
end
