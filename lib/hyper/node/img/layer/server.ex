defmodule Hyper.Node.Img.Layer.Server do
  @moduledoc """
  Server which provides layers to the current node. Although it is called _Server_ here, in
  the network topology, this is actually a client to the actual data-storage server.

  It is called the _Server_ within the context of the node, because, for the node, it serves
  images to Firecracker.
  """
end
