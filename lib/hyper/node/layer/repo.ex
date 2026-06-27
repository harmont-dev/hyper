defmodule Hyper.Node.Layer.Repo do
  @moduledoc """
  Repo for looking up layers in the shared layer directory. Currently backed by a flat
  file-directory.

  Hyper expects you to keep your layers in a flat directory, which may be backed by anything you
  like: a plain filesystem, an NFS drive. This registry only ever is used to find paths to layers
  but not anything more.
  """

  use OpenTelemetryDecorator

  @doc "Test whether the system appears configured for the node registry."
  @spec test_system() :: :ok | {:error, term()}
  @decorate with_span("Hyper.Node.Layer.Repo.test_system")
  def test_system do
    cond do
      not File.exists?(Hyper.Cfg.Dirs.layer_dir()) -> {:error, :layer_dir_not_found}
      not File.dir?(Hyper.Cfg.Dirs.layer_dir()) -> {:error, :layer_dir_not_dir}
      true -> :ok
    end
  end

  @doc "Resolve a layer's path. `{:error, :enoent}` if absent, `{:error, posix}` on I/O error."
  @spec find_layer(Hyper.Layer.id()) :: {:ok, Path.t()} | {:error, File.posix()}
  @decorate with_span("Hyper.Node.Layer.Repo.find_layer")
  def find_layer(id) do
    path = Path.join([Hyper.Cfg.Dirs.layer_dir(), layer_basename(id)])

    case File.stat(path) do
      {:ok, _stat} -> {:ok, path}
      {:error, posix} -> {:error, posix}
    end
  end

  # Return the basename of the given layer.
  @spec layer_basename(Hyper.Layer.id()) :: String.t()
  defp layer_basename(id), do: "layer_#{id}.img"
end
