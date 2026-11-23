defmodule Hyper.GuestServiceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Hyper.GuestService
  alias Unit.Time

  defmodule Admin do
    @moduledoc false
    @behaviour Hyper.GuestService.Handler
    def name, do: Process.get(:admin_name, "admin")
    def init(_conn, arg), do: {:ok, arg}
    def handle_data(_data, state), do: {:continue, state}
  end

  defmodule Twin do
    @moduledoc false
    @behaviour Hyper.GuestService.Handler
    def name, do: "admin"
    def init(_conn, arg), do: {:ok, arg}
    def handle_data(_data, state), do: {:continue, state}
  end

  defmodule Named do
    @moduledoc false
    def init(_conn, arg), do: {:ok, arg}
    def handle_data(_data, state), do: {:continue, state}
    def name, do: Process.get(:named_name)
  end

  defmodule NotAHandler do
    @moduledoc false
    def name, do: "lonely"
  end

  defp service(mod, overrides \\ []), do: struct!(%GuestService{handler: {mod, :arg}}, overrides)

  test "resolution fills in the name the handler gives, and keeps the rest" do
    assert {:ok, [%GuestService{name: "admin", handler: {Admin, :arg}, max_connections: 3}]} =
             GuestService.resolve_all([service(Admin, max_connections: 3)])
  end

  test "a resolved name is kept, so a handler whose name/0 changed does not rename the service" do
    {:ok, resolved} = GuestService.resolve_all([service(Admin)])
    Process.put(:admin_name, "renamed")

    assert GuestService.resolve_all(resolved) == {:ok, resolved}
  end

  test "a handler naming its service outside [a-z0-9_-]{1,255}, or under hyper-, is refused" do
    rows = [
      {"Admin", :name},
      {"", :name},
      {String.duplicate("a", 256), :name},
      {:admin, :name},
      {"hyper-status", :reserved_name}
    ]

    for {name, reason} <- rows do
      Process.put(:named_name, name)

      assert GuestService.resolve_all([service(Named)]) ==
               {:error, {:invalid_guest_service, Named, reason}},
             inspect(name)
    end
  end

  test "malformed services are refused with the reason" do
    rows = [
      {[service(Admin, max_connections: 0)], {:invalid_guest_service, Admin, :max_connections}},
      {[service(Admin, idle_timeout: Time.ms(0))],
       {:invalid_guest_service, Admin, :idle_timeout}},
      {[%GuestService{handler: Admin}], {:invalid_guest_service, Admin, :handler}},
      {[service(Admin), service(Twin)], {:duplicate_guest_service, "admin"}},
      {[service(NotAHandler)], {:guest_service_handler_not_loaded, NotAHandler}},
      {[service(Hyper.GuestServiceTest.Missing)],
       {:guest_service_handler_not_loaded, Hyper.GuestServiceTest.Missing}}
    ]

    for {services, reason} <- rows do
      assert GuestService.resolve_all(services) == {:error, reason}, inspect(reason)
    end
  end

  test "the handler's argument never shows up when a service is inspected" do
    refute inspect(%GuestService{handler: {Admin, "s3cr3t-token"}}) =~ "s3cr3t-token"
  end

  test "ensure_loaded refuses the first service whose handler is missing" do
    assert GuestService.ensure_loaded([service(Admin)]) == :ok

    assert GuestService.ensure_loaded([service(Admin), service(NotAHandler)]) ==
             {:error, {:guest_service_handler_not_loaded, NotAHandler}}
  end
end
