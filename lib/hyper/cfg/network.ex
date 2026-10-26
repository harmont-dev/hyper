defmodule Hyper.Cfg.Network do
  @moduledoc "VM networking configuration."

  @doc "Unimplemented: the DNS resolvers handed to guests."
  @spec resolvers() :: [:inet.ip_address()]
  def resolvers,
    do: raise("Hyper.Cfg.Network.resolvers/0 is unimplemented: VM networking is being rewritten")
end
