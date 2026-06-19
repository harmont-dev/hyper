defmodule Hyper.Img.Db.Repo do
  @moduledoc """
  Global database of all known layers, and how they relate to each other.

  At the current stage of this project, we use postgres to track images and how they relate.
  Note that images can build on top of images.

  This repo is responsible for answering the questions:
    - Given an image id, is it a base image or a layered image?
    - If an image is a layered image, what are the layers to build it?
    - Who is currently actively holding onto an image? This can mean, potentially, in the case of
      layered images:
      - Who is holding onto the image or any of its children?
  """

  use Ecto.Repo,
    otp_app: :hyper,
    adapter: Ecto.Adapters.Postgres
end
