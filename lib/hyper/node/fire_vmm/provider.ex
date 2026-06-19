defmodule Hyper.Node.FireVMM.Provider do
  @moduledoc """
  Downloads and installs the firecracker + jailer binaries for the current
  architecture into `Hyper.Config.firecracker_install_dir/0`
  (`<work_dir>/redist/firecracker`).

  `ensure_installed/1` is idempotent: if the binaries for the pinned version are
  already present and executable it returns `:ok` without touching the network.
  Otherwise it downloads the official firecracker release tarball for the
  detected architecture into a temporary directory, verifies its SHA-256 against
  a pinned digest, extracts it, copies `firecracker` and `jailer` into the
  install dir, and removes the temporary directory (always, via `try/after`).

  The checksum is pinned here on purpose: downloading the `*.sha256.txt` from the
  same host as the tarball would be trust-on-first-use and provide no real
  integrity guarantee. Pinning the digest is what makes the check meaningful.
  """

  @version "1.16.0"

  # SHA-256 of the official release tarballs, pinned per architecture. Contents
  # of firecracker-v<ver>-<arch>.tgz.sha256.txt from the GitHub release.
  @checksums %{
    "x86_64" => "bd04e26952d4e158085778c6230a0b383d2619c319182e27eaa9d61a212e92d6",
    "aarch64" => "531c713cdbc37d4b8bc2533d851aabc0267096afa1768086a37672abb668efd7"
  }

  @github_base "https://github.com/firecracker-microvm/firecracker/releases/download"

  @doc "Detect the firecracker arch string for the current machine."
  @spec target_arch() :: {:ok, String.t()} | {:error, {:unsupported_arch, String.t()}}
  def target_arch do
    sys = to_string(:erlang.system_info(:system_architecture))

    cond do
      String.contains?(sys, "x86_64") -> {:ok, "x86_64"}
      String.contains?(sys, "amd64") -> {:ok, "x86_64"}
      String.contains?(sys, "aarch64") -> {:ok, "aarch64"}
      String.contains?(sys, "arm64") -> {:ok, "aarch64"}
      true -> {:error, {:unsupported_arch, sys}}
    end
  end
end
