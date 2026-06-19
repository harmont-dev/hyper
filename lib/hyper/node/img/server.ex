defmodule Hyper.Node.Img.Server do
  @moduledoc """
  Behaviour for a block-device server backing a VM's images.

  `use Hyper.Node.Img.Server` marks the module as a server and injects
  `with_image/2`, which opens a device, runs the callable, then closes it — on
  the module it is called in.
  """

  require Logger

  alias Hyper.Node.Img

  @type blkdev_path :: Path.t()

  @callback open_block_device(Img.image_id()) :: {:ok, blkdev_path()} | {:error, term()}
  @callback close_block_device(blkdev_path()) :: :ok | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour Hyper.Node.Img.Server

      @doc "Open this server's block device for `img`, run `callable` with it, then close it."
      def with_image(img, callable) do
        Hyper.Node.Img.Server.with_image(__MODULE__, img, callable)
      end
    end
  end

  @doc false
  @spec with_image(module(), Img.image_id(), (blkdev_path() -> result)) ::
          result | {:error, term()}
        when result: var
  def with_image(server, img, callable) do
    with {:ok, blkdev} <- server.open_block_device(img) do
      try do
        callable.(blkdev)
      after
        case server.close_block_device(blkdev) do
          :ok -> :ok
          {:error, reason} -> Logger.error("failed to close block device: #{inspect(reason)}")
        end
      end
    end
  end
end
