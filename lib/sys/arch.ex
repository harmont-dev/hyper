defmodule Sys.Arch do
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
    parse(to_string(:erlang.system_info(:system_architecture)))
  end

  @doc """
  Classify a raw architecture string (a target triplet or a bare arch name)
  into a supported architecture. An unrecognised string is refused with
  `{:error, {:unsupported_arch, raw}}`, echoing the input.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:unsupported_arch, String.t()}}
  def parse(sys) do
    cond do
      String.contains?(sys, "x86_64") -> {:ok, :x86_64}
      String.contains?(sys, "amd64") -> {:ok, :x86_64}
      String.contains?(sys, "aarch64") -> {:ok, :aarch64}
      String.contains?(sys, "arm64") -> {:ok, :aarch64}
      true -> {:error, {:unsupported_arch, sys}}
    end
  end

  @doc "Map an architecture to the Go/OCI arch name (`skopeo --override-arch`, image manifests)."
  @spec goarch(t()) :: String.t()
  def goarch(:x86_64), do: "amd64"
  def goarch(:aarch64), do: "arm64"
end
