defmodule Hyper.Http.Plugs.VerifyRequest do
  @moduledoc """
   Verify specific fields in a request body
  """

  defmodule IncompleteRequestError do
    @moduledoc """
      Error raised when a required field is missing.
    """
    defexception message: "", plug_status: 400
  end

  def init(options), do: options

  def call(conn, opts) do
    %Plug.Conn{
      request_path: path,
      method: method,
      body_params: payload
    } = conn

    if requires_verification?(path, method) do
      verify_request!(payload, opts[:fields])
    end

    conn
  end

  def verify_request!(params, fields) do
    keys = Map.keys(params)

    if !contains_fields?(fields) do
      missing_fields = fields -- keys

      raise IncompleteRequestError,
        message: "missing required field(s): #{Enum.join(missing_fields, ", ")}"
    end
  end

  # change this to simple methods to verify the required fields and _  for missing fields
  # defp contains_fields?(keys, fields), do: Enum.all?(fields, fn x -> x in keys end)

  defp contains_fields?(%{
         "image" => _,
         "boot_args" => _,
         "type" => _,
         "architecture" => _,
         "label" => _
       }),
       do: true

  defp contains_fields?(%{"image" => _, "boot_args" => _, "type" => _}), do: true
  defp contains_fields?(_), do: false

  defp requires_verification?(["/v1/vms"], "POST"), do: true
  defp requires_verification?(_, _), do: false
end
