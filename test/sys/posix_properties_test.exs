defmodule Sys.PosixPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Posix
  alias Sys.Tmp

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o7777)

  property "mkdir_private creates every missing component 0700 and leaves existing ones alone" do
    check all(
            names <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                min_length: 1,
                max_length: 5
              ),
            existing <- integer(0..(length(names) - 1)),
            existing_mode <- member_of([0o755, 0o775, 0o711, 0o700])
          ) do
      Tmp.with_tempdir(fn root ->
        dirs = Enum.scan(names, root, &Path.join(&2, &1))
        {present, missing} = Enum.split(dirs, existing)

        for dir <- present do
          File.mkdir!(dir)
          File.chmod!(dir, existing_mode)
        end

        assert Posix.mkdir_private(List.last(dirs)) == :ok
        assert Enum.all?(present, &(mode(&1) == existing_mode))
        assert Enum.all?(missing, &(mode(&1) == 0o700))
        assert Posix.mkdir_private(List.last(dirs)) == :ok
      end)
    end
  end
end
