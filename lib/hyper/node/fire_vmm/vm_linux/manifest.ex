defmodule Hyper.Node.FireVMM.VmLinux.Manifest do
  @moduledoc """
  The statically-embedded vmlinux release manifest.

  `priv/vmlinux/manifest.json` is vendored verbatim from a pinned
  `github.com/harmont-dev/hyper-vmlinux` release and read at compile time, so the
  per-build SHA-256 sums (used by `Hyper.Node.FireVMM.VmLinux.Provider` to verify
  downloads) are baked into the compiled module and cannot drift from what was
  published. `@external_resource` forces a recompile if the file changes.

  All functions here are pure; they never touch the network or the filesystem.
  """

  alias Hyper.Node.FireVMM.VmLinux.Manifest.Build

  @repo "harmont-dev/hyper-vmlinux"
  @manifest_path "priv/vmlinux/manifest.json"
  @external_resource @manifest_path

  @decoded @manifest_path |> File.read!() |> Jason.decode!()
  @sha @decoded["sha"]
  @builds (for b <- @decoded["builds"] do
             arch =
               case b["arch"] do
                 "x86_64" -> :x86_64
                 "aarch64" -> :aarch64
               end

             %Build{
               name: b["name"],
               arch: arch,
               version: b["version"],
               asset: b["asset"],
               sha256: b["sha256"]
             }
           end)

  @doc "All builds in the manifest."
  @spec builds() :: [Build.t()]
  def builds, do: @builds

  @doc "All builds matching `arch`."
  @spec builds_for(Sys.Arch.t()) :: [Build.t()]
  def builds_for(arch), do: Enum.filter(@builds, &(&1.arch == arch))

  @doc "Look up a build by its `name` (e.g. \"x86_64-6.1\")."
  @spec fetch(String.t()) :: {:ok, Build.t()} | :error
  def fetch(name) do
    case Enum.find(@builds, &(&1.name == name)) do
      nil -> :error
      build -> {:ok, build}
    end
  end

  @doc """
  The default build for `arch`: the highest `version`, breaking ties toward the
  shorter `name` (so a plain build wins over a variant like `-no-acpi`). Returns
  `nil` if the manifest has no build for `arch`.
  """
  @spec default_for(Sys.Arch.t()) :: Build.t() | nil
  def default_for(arch) do
    arch
    |> builds_for()
    |> Enum.sort(&preferred?/2)
    |> List.first()
  end

  @doc "The download URL for `build`'s asset on the pinned release."
  @spec asset_url(Build.t()) :: String.t()
  def asset_url(%Build{asset: asset}) do
    "https://github.com/#{@repo}/releases/download/release-#{@sha}/#{asset}"
  end

  # True if `a` is the more-preferred default than `b`: higher version first,
  # then shorter name (plain build over variant).
  defp preferred?(%Build{} = a, %Build{} = b) do
    case Version.compare(a.version, b.version) do
      :gt -> true
      :lt -> false
      :eq -> String.length(a.name) <= String.length(b.name)
    end
  end
end
