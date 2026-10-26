defmodule Sys.Linux.KernelPropertiesTest do
  @moduledoc """
  Laws of `Kernel.parse_release/1`:

    * round-trip — any `major.minor.patch` followed by a distro suffix parses
      back to exactly `{major, minor, patch}`, so the suffix never shifts the
      version;
    * refusal — a release candidate is always `:prerelease`, never read as the
      final release it precedes.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Kernel

  defp component, do: integer(0..400)

  # Distro suffixes start with a separator, never a digit or dot, which would
  # extend the version itself.
  defp suffix do
    one_of([
      constant(""),
      map(
        {member_of(["-", "+", "_", "~"]), string(:printable, max_length: 24)},
        fn {sep, tail} -> sep <> tail end
      )
    ])
  end

  property "major.minor.patch round-trips through any distro suffix" do
    check all(maj <- component(), min <- component(), patch <- component(), s <- suffix()) do
      assert Kernel.parse_release("#{maj}.#{min}.#{patch}#{s}") == {:ok, {maj, min, patch}}
    end
  end

  property "a release candidate is refused, never read as its final release" do
    check all(maj <- component(), min <- component(), rc <- integer(1..12)) do
      assert Kernel.parse_release("#{maj}.#{min}-rc#{rc}") == {:error, :prerelease}
    end
  end

  test "real-world release strings" do
    for {release, expected} <- [
          {"6.8.0-147-generic", {:ok, {6, 8, 0}}},
          {"6.1.0-37-amd64", {:ok, {6, 1, 0}}},
          {"6.15.4-200.fc42.x86_64", {:ok, {6, 15, 4}}},
          {"6.12.101-arch1-1", {:ok, {6, 12, 101}}},
          {"7.2", {:ok, {7, 2, 0}}},
          {"7.2-rc5", {:error, :prerelease}},
          {"2.6.32.1", {:error, :invalid_release}},
          {"linux", {:error, :invalid_release}}
        ] do
      assert Kernel.parse_release(release) == expected, release
    end
  end
end
