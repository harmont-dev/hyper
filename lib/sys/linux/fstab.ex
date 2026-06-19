defmodule Sys.Linux.Fstab do
  @moduledoc "Parsing of `/etc/fstab`-style entries."

  defmodule Spec do
    @moduledoc "A parsed `/etc/fstab` entry."

    @type t :: %__MODULE__{
            device: String.t(),
            mount_point: Path.t(),
            fs_type: String.t(),
            mount_opts: [String.t()]
          }

    defstruct [:device, :mount_point, :fs_type, :mount_opts]
  end

  @doc """
  Parse a single fstab line into a `Spec`.

  fstab fields are whitespace-separated: `device mount_point fs_type options [dump] [pass]`.
  The dump/pass columns are ignored; `options` is split on commas. Blank lines and
  `#` comments yield `{:error, :invalid_format}`.
  """
  @spec parse(String.t()) :: {:ok, Spec.t()} | {:error, :invalid_format}
  def parse(fstab_line) do
    case fstab_line |> String.trim() |> fields() do
      [device, mount_point, fs_type, opts | _dump_pass] ->
        {:ok,
         %Spec{
           device: device,
           mount_point: mount_point,
           fs_type: fs_type,
           mount_opts: String.split(opts, ",", trim: true)
         }}

      _ ->
        {:error, :invalid_format}
    end
  end

  # Whitespace-separated fields; blank lines and comments collapse to [].
  defp fields(""), do: []
  defp fields("#" <> _), do: []
  defp fields(line), do: String.split(line)
end
