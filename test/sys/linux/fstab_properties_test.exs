defmodule Sys.Linux.FstabPropertiesTest do
  @moduledoc """
  Generative round-trip for fstab lines: render a well-formed entry from random
  fields, parse it, and assert every field is recovered (options comma-split,
  the dump/pass columns ignored). Plus the structural rules: comments and blank
  lines are rejected, and a line with fewer than four fields is invalid.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Fstab

  # A single fstab token: no whitespace, no comma (commas separate options),
  # non-empty. Restricting to a safe charset keeps rendered lines unambiguous.
  defp token, do: string([?a..?z, ?A..?Z, ?0..?9, ?/, ?-, ?_, ?.], min_length: 1, max_length: 12)
  defp opts, do: list_of(token(), min_length: 1, max_length: 5)

  property "round-trips device, mount_point, fs_type, and comma-split options" do
    check all(
            device <- token(),
            mount_point <- token(),
            fs_type <- token(),
            mount_opts <- opts()
          ) do
      line = "#{device} #{mount_point} #{fs_type} #{Enum.join(mount_opts, ",")}"
      assert {:ok, spec} = Fstab.parse(line)
      assert spec.device == device
      assert spec.mount_point == mount_point
      assert spec.fs_type == fs_type
      assert spec.mount_opts == mount_opts
    end
  end

  property "the dump and pass columns are ignored" do
    check all(
            device <- token(),
            mount_point <- token(),
            fs_type <- token(),
            mount_opts <- opts(),
            dump <- integer(0..9),
            pass <- integer(0..9)
          ) do
      line = "#{device} #{mount_point} #{fs_type} #{Enum.join(mount_opts, ",")} #{dump} #{pass}"
      assert {:ok, spec} = Fstab.parse(line)
      assert spec.device == device
      assert spec.mount_opts == mount_opts
    end
  end

  property "extra leading/trailing whitespace does not change the parse" do
    check all(device <- token(), mount_point <- token(), fs_type <- token(), o <- token()) do
      line = "   #{device}   #{mount_point}  #{fs_type}   #{o}   "
      assert {:ok, spec} = Fstab.parse(line)
      assert spec.device == device
      assert spec.mount_opts == [o]
    end
  end

  property "comment and blank lines are rejected" do
    check all(
            ws <- string([?\s, ?\t], max_length: 4),
            rest <- string(:printable, max_length: 20)
          ) do
      assert Fstab.parse(ws) == {:error, :invalid_format} or String.trim(ws) != ""
      assert Fstab.parse("#" <> rest) == {:error, :invalid_format}
    end
  end

  property "a line with fewer than four fields is invalid" do
    check all(fields <- list_of(token(), min_length: 0, max_length: 3)) do
      assert Fstab.parse(Enum.join(fields, " ")) == {:error, :invalid_format}
    end
  end
end
