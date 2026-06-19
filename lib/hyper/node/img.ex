defmodule Hyper.Node.Img do
  @moduledoc "Operations on images used to seed firecracker devices."

  @type image_id :: String.t()
  @type t :: {:base, image_id()} | {:layered, image_id()}
end
