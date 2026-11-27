defmodule Hyper.Http.RouterTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias Hyper.Http.Router

  @opts Router.init([])

  setup do
    previous = Application.get_env(:hyper, Hyper.Http.Server)
    on_exit(fn -> Application.put_env(:hyper, Hyper.Http.Server, previous) end)
    :ok
  end

  test "Hyper System is live" do
    conn =
      :get
      |> conn("/health")
      |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 200
  end

  test "Hyper System is ready: database and cluster are up" do
    Application.put_env(:hyper, Hyper.Http.Server,
      ready: fn -> {:ok, %{"database" => "up", "cluster" => "up"}} end
    )

    conn =
      :get
      |> conn("/ready")
      |> Router.call(@opts)

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "status" => "Hyper System DB and Cluster are ready"
           }
  end

  test "Hyper System is not ready: database is down and cluster is up" do
    Application.put_env(:hyper, Hyper.Http.Server,
      ready: fn -> {:error, %{"database" => "down", "cluster" => "up"}} end
    )

    conn =
      :get
      |> conn("/ready")
      |> Router.call(@opts)

    assert conn.status == 503

    assert Jason.decode!(conn.resp_body) == %{
             "status" => "Hyper System DB and Cluster not ready, Please try again later"
           }
  end

  test "Hyper System is not ready: database is up and cluster is down" do
    Application.put_env(:hyper, Hyper.Http.Server,
      ready: fn -> {:error, %{"database" => "up", "cluster" => "down"}} end
    )

    conn =
      :get
      |> conn("/ready")
      |> Router.call(@opts)

    assert conn.status == 503

    assert Jason.decode!(conn.resp_body) == %{
             "status" => "Hyper System DB and Cluster not ready, Please try again later"
           }
  end

  test "returns 404" do
    conn =
      :get
      |> conn("/missing", "")
      |> Router.call(@opts)

    assert conn.state == :sent
    assert conn.status == 404
  end

  test "/v1/vms returns the page as JSON" do
    Application.put_env(:hyper, Hyper.Http.Server,
      list_vms: fn
        2, "tok" -> {:ok, [%{vm_id: "vm-1", node: "node_a"}], "next"}
        _, _ -> {:ok, [], ""}
      end
    )

    conn =
      :get
      |> conn("/v1/vms?page_size=2&page_token=tok")
      |> Router.call(@opts)

    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "vms" => [%{"vm_id" => "vm-1", "node" => "node_a"}],
             "next_page_token" => "next"
           }
  end

  test "/v1/vms returns 400" do
    Application.put_env(:hyper, Hyper.Http.Server,
      list_vms: fn
        2, "bogus_token" -> {:error, :bad_page_token}
        _, _ -> {:ok, [], ""}
      end
    )

    conn =
      :get
      |> conn("/v1/vms?page_token=bogus")
      |> Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "bad_page_token"}
  end

  # test for post errors
end
