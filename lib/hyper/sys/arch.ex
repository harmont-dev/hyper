defmodule Hyper.Sys.Arch do
  @moduledoc "CPU architecture detection for the current machine."

  @typedoc "A CPU architecture Hyper supports."
  @type t :: :x86_64 | :aarch64

  @doc """
  Detect the CPU architecture of the current machine.

  Returns the architecture as an atom, or `{:error, {:unsupported_arch, raw}}`
  where `raw` is the unrecognised `:erlang.system_info(:system_architecture)`
  string.
  """
  @spec current() :: {:ok, t()} | {:error, {:unsupported_arch, String.t()}}
  def current do
    sys = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.contains?(sys, "x86_64") -> {:ok, :x86_64}
      String.contains?(sys, "amd64") -> {:ok, :x86_64}
      String.contains?(sys, "aarch64") -> {:ok, :aarch64}
      String.contains?(sys, "arm64") -> {:ok, :aarch64}
      true -> {:error, {:unsupported_arch, sys}}
    end
  end
end
