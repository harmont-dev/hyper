defmodule Sys.Linux.Kvm do
  @moduledoc "Host KVM module state, read from `/sys/module/kvm_{intel,amd}/parameters`."

  @vendor_modules ~w(kvm_intel kvm_amd)

  @doc """
  Whether nested virtualization is enabled in the loaded KVM vendor module(s).

  `:unknown` when no vendor module exposes the parameter (KVM not loaded yet,
  or an unreadable sysfs): the module may still load later with nesting on.
  """
  @spec nested() :: boolean() | :unknown
  def nested do
    @vendor_modules
    |> Enum.map(&File.read("/sys/module/#{&1}/parameters/nested"))
    |> Enum.flat_map(fn
      {:ok, raw} -> [parse_nested(raw)]
      {:error, _} -> []
    end)
    |> combine()
  end

  @doc """
  Decode a `nested` module parameter: `kvm_intel` prints a bool (`Y`/`N`),
  `kvm_amd` an int (`1`/`0`). Anything else is `:unknown`.
  """
  @spec parse_nested(String.t()) :: boolean() | :unknown
  def parse_nested(raw) do
    case String.trim(raw) do
      v when v in ["Y", "1"] -> true
      v when v in ["N", "0"] -> false
      _ -> :unknown
    end
  end

  defp combine([]), do: :unknown

  defp combine(states) do
    cond do
      true in states -> true
      :unknown in states -> :unknown
      true -> false
    end
  end
end
