defmodule Hyper.Grpc.WarningTest do
  use ExUnit.Case, async: true

  alias Hyper.Cfg.Grpc, as: Config

  test "warns when enabled without TLS" do
    msg = Hyper.Grpc.auth_warning(%Config{enabled: true, cred: nil})
    assert msg =~ "no authentication"
  end

  test "still warns when enabled with TLS (TLS is encryption, not authn)" do
    assert Hyper.Grpc.auth_warning(%Config{enabled: true, cred: :some_cred})
  end

  test "silent when disabled" do
    assert Hyper.Grpc.auth_warning(%Config{enabled: false, cred: nil}) == nil
  end
end
