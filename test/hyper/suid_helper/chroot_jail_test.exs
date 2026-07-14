defmodule Hyper.SuidHelper.ChrootJailTest do
  @moduledoc """
  `grant_api/1` and `grant_vsock/1` translate the helper's `result` field into
  the caller's retry protocol: "granted" → `:ok`, "pending" → `{:error,
  :socket_pending}` (keep waiting). Kills a mutation that swaps these — which
  would either spin forever on a ready socket or give up on a pending one.
  """
  use ExUnit.Case, async: false

  alias Hyper.SuidHelper.ChrootJail
  alias Hyper.Test.FakeSuidhelper

  for {fun, name} <- [{:grant_api, "grant_api/1"}, {:grant_vsock, "grant_vsock/1"}] do
    test "#{name} maps a granted socket to :ok" do
      FakeSuidhelper.install!(~s|echo '{"result":"granted"}'|)
      assert :ok = apply(ChrootJail, unquote(fun), ["/run/vm/socket"])
    end

    test "#{name} maps a not-yet-created socket to {:error, :socket_pending}" do
      FakeSuidhelper.install!(~s|echo '{"result":"pending"}'|)
      assert {:error, :socket_pending} = apply(ChrootJail, unquote(fun), ["/run/vm/socket"])
    end
  end
end
