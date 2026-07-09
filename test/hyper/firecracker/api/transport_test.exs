defmodule Hyper.Firecracker.Api.TransportTest do
  @moduledoc """
  Result contract of the Firecracker transport, exercised over a real
  Unix-socket HTTP server: 2xx classification against the operation's
  response spec (`:ok` for `:null`, typed decode for `{module, :t}`, raw
  passthrough otherwise), non-2xx fault extraction, and connection failures
  as `{:error, {:transport, _}}` — never a raise. Also pins the wire shape:
  Codec-encoded bodies arrive nil-stripped, query params land in the
  request line.
  """
  use ExUnit.Case, async: true

  alias Hyper.Firecracker.Api.{Drive, InstanceInfo, Transport}
  alias Hyper.Firecracker.Support.UnixHttp

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp request(socket_path, extra) do
    Map.merge(%{method: :get, url: "/", opts: [socket_path: socket_path]}, Map.new(extra))
  end

  test "204 against a :null response spec is :ok" do
    path = UnixHttp.start(fn _req -> {204, ""} end)

    assert Transport.request(
             request(path, method: :put, url: "/actions", response: [{204, :null}])
           ) == :ok
  end

  test "2xx with a typed response spec decodes into the schema struct" do
    body = ~s({"id":"vm-1","state":"Running","vmm_version":"1.9.0","app_name":"Firecracker"})
    path = UnixHttp.start(fn _req -> {200, body} end)

    assert Transport.request(request(path, response: [{200, {InstanceInfo, :t}}])) ==
             {:ok,
              %InstanceInfo{
                id: "vm-1",
                state: "Running",
                vmm_version: "1.9.0",
                app_name: "Firecracker"
              }}
  end

  test "2xx with no matching spec: raw body passthrough, :ok when empty" do
    json = UnixHttp.start(fn _req -> {200, ~s({"free":"form"})} end)
    assert Transport.request(request(json, [])) == {:ok, %{"free" => "form"}}

    empty = UnixHttp.start(fn _req -> {200, ""} end)
    assert Transport.request(request(empty, [])) == :ok
  end

  test "non-2xx surfaces {:api, status, fault_message}; nil when the body has none" do
    faulted = UnixHttp.start(fn _req -> {400, ~s({"fault_message":"Invalid drive"})} end)
    assert Transport.request(request(faulted, [])) == {:error, {:api, 400, "Invalid drive"}}

    opaque = UnixHttp.start(fn _req -> {500, ~s({"unexpected":"shape"})} end)
    assert Transport.request(request(opaque, [])) == {:error, {:api, 500, nil}}
  end

  test "a connection failure is {:error, {:transport, _}}, never a raise" do
    missing = Path.join(System.tmp_dir!(), "no-such-#{System.unique_integer([:positive])}.sock")
    assert {:error, {:transport, _reason}} = Transport.request(request(missing, []))
  end

  test "wire shape: body arrives as nil-stripped JSON, query params in the request line" do
    path = UnixHttp.start(fn _req -> {204, ""} end)
    drive = %Drive{drive_id: "rootfs", is_root_device: false}

    assert :ok =
             Transport.request(
               request(path,
                 method: :put,
                 url: "/drives/rootfs",
                 body: drive,
                 query: [foo: "bar"],
                 response: [{204, :null}]
               )
             )

    assert_receive {:unix_http, %{method: :PUT, path: req_path, body: wire_body}}
    assert req_path == "/drives/rootfs?foo=bar"
    assert Jason.decode!(wire_body) == %{"drive_id" => "rootfs", "is_root_device" => false}
  end
end
