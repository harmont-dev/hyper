defmodule Hyper.Test.FirecrackerRecordingClient do
  @moduledoc """
  Test stand-in for `Hyper.Firecracker.Api.Transport`. Generated operations call
  `request/1`; this records the call and returns a canned result, so the boot
  flow can be exercised without a real Firecracker daemon or unix socket.

  Pass it through a `run` closure as the operation's `:client`, with two extra
  opts it reads from the call's `:opts`:

    * `:recorder` - a pid; receives `{:fc_call, method, url, body}` per call.
    * `:respond`  - a 1-arity fun `info -> result`; its return value is handed
      back verbatim (mimicking Transport's `:ok | {:ok, term} | {:error, term}`).
      Defaults to always `:ok`.
  """

  @spec request(map()) :: term()
  def request(%{method: method, url: url, opts: opts} = info) do
    if pid = opts[:recorder], do: send(pid, {:fc_call, method, url, Map.get(info, :body)})
    respond = opts[:respond] || fn _info -> :ok end
    respond.(info)
  end
end
