defmodule Sys.Linux.Kernel do
  @moduledoc """
  The running kernel's release, as reported by `/proc/sys/kernel/osrelease`
  (the same string as `uname -r`).
  """

  @osrelease "/proc/sys/kernel/osrelease"

  @typedoc "An upstream `{major, minor, patch}` kernel version."
  @type version :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}

  @doc "The running kernel's upstream version, parsed from its release string."
  @spec version() :: {:ok, version()} | {:error, term()}
  def version do
    with {:ok, release} <- File.read(@osrelease) do
      parse_release(String.trim(release))
    end
  end

  @doc """
  Parse the leading upstream `major.minor[.patch]` of a release string,
  ignoring any distro suffix (`6.8.0-147-generic` → `{6, 8, 0}`).

  Release candidates (`7.2-rc5`) are refused with `{:error, :prerelease}`:
  `7.2-rc1` predates `7.2`, and reading it as `{7, 2, 0}` would overstate it.
  """
  @spec parse_release(String.t()) ::
          {:ok, version()} | {:error, :prerelease | :invalid_release}
  def parse_release(release) do
    case Regex.run(~r/\A(\d+)\.(\d+)(?:\.(\d+))?(.*)\z/s, release) do
      [_, _, _, _, "-rc" <> _] -> {:error, :prerelease}
      [_, maj, min, patch, rest] -> build(maj, min, patch, rest)
      nil -> {:error, :invalid_release}
    end
  end

  defp build(maj, min, patch, rest) do
    if rest == "" or not String.match?(rest, ~r/\A[\d.]/) do
      {:ok, {String.to_integer(maj), String.to_integer(min), patch_number(patch)}}
    else
      {:error, :invalid_release}
    end
  end

  defp patch_number(""), do: 0
  defp patch_number(patch), do: String.to_integer(patch)
end
