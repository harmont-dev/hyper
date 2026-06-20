defmodule Hyper.Node.FireVMM.ClientTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Client
  alias Hyper.Node.FireVMM.Client.Schema.{BootSource, InstanceActionInfo}

  defp client(plug) do
    {:ok, pid} =
      Client.start_link(%Client.Opts{
        vm_id: nil,
        socket_path: "/unused",
        name: nil,
        req_options: [plug: plug]
      })

    pid
  end

  test "instance_info issues GET / and decodes 200 JSON" do
    pid =
      client(fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/"
        Req.Test.json(conn, %{"state" => "Running", "id" => "vm1"})
      end)

    assert {:ok, %{"state" => "Running", "id" => "vm1"}} = Client.instance_info(pid)
  end

  test "put_boot_source issues PUT /boot-source with compacted body and maps 204 to :ok" do
    pid =
      client(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/boot-source"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"kernel_image_path" => "/vmlinux"}
        Plug.Conn.send_resp(conn, 204, "")
      end)

    assert :ok = Client.put_boot_source(pid, %BootSource{kernel_image_path: "/vmlinux"})
  end

  test "action maps a 4xx Error body to {:error, {:api, status, fault}}" do
    pid =
      client(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{"fault_message" => "nope"}))
      end)

    assert {:error, {:api, 400, "nope"}} =
             Client.action(pid, %InstanceActionInfo{action_type: "InstanceStart"})
  end

  test "put_drive builds the path from drive_id" do
    pid =
      client(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/drives/rootfs"
        Plug.Conn.send_resp(conn, 204, "")
      end)

    drive = %Hyper.Node.FireVMM.Client.Schema.Drive{drive_id: "rootfs", is_root_device: true}
    assert :ok = Hyper.Node.FireVMM.Client.put_drive(pid, drive)
  end

  test "put_mmds preserves nil values verbatim and uses PUT" do
    pid =
      client(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/mmds"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"token" => nil, "ami-id" => "ami-1"}
        Plug.Conn.send_resp(conn, 204, "")
      end)

    assert :ok = Hyper.Node.FireVMM.Client.put_mmds(pid, %{"token" => nil, "ami-id" => "ami-1"})
  end

  test "put_mmds sends an arbitrary JSON map verbatim" do
    pid =
      client(fn conn ->
        assert conn.request_path == "/mmds"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"latest" => %{"meta-data" => %{"ami-id" => "ami-1"}}}
        Plug.Conn.send_resp(conn, 204, "")
      end)

    assert :ok =
             Hyper.Node.FireVMM.Client.put_mmds(pid, %{
               "latest" => %{"meta-data" => %{"ami-id" => "ami-1"}}
             })
  end
end
