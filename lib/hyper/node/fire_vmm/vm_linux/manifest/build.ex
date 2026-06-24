defmodule Hyper.Node.FireVMM.VmLinux.Manifest.Build do
  @moduledoc "One kernel build from the manifest."
  @enforce_keys [:name, :arch, :version, :asset, :sha256]
  defstruct [:name, :arch, :version, :asset, :sha256]

  @type t :: %__MODULE__{
          name: String.t(),
          arch: Sys.Arch.t(),
          version: String.t(),
          asset: String.t(),
          sha256: String.t()
        }
end
