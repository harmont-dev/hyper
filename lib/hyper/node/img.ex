defmodule Hyper.Node.Img do
  @moduledoc "Operations on images used to seed firecracker devices."

  alias Hyper.Img.Db.Lease

  @type t :: String.t()

  @doc """
  Serve `img` to `vm_id` for the duration of `callable`, holding a DB lease on the
  image (and transitively its whole blob chain) the whole time.
  """
  @spec with_image(t(), Hyper.Vm.id(), (-> result)) :: result | {:error, term()} when result: var
  def with_image(img, vm_id, callable) do
    with_image_lease(img, vm_id, callable)
  end

  # Take a lease on `img` for this node/`vm_id`, run `callable`, then release it —
  # even if `callable` raises. A background task re-bumps the lease every half-TTL
  # for the whole run, so a long-lived VM never lets its claim lapse. If the lease
  # cannot be taken, returns the error and never runs `callable`.
  @spec with_image_lease(t(), Hyper.Vm.id(), (-> result)) :: result | {:error, term()}
        when result: var
  defp with_image_lease(img, vm_id, callable) do
    ttl = Lease.default_ttl()

    with {:ok, _lease} <- Lease.bump(img, vm_id, ttl) do
      task = Task.async(fn -> heartbeat(img, vm_id, ttl) end)

      try do
        callable.()
      after
        _ = Task.shutdown(task, :brutal_kill)
        :ok = Lease.release(vm_id)
      end
    end
  end

  # Re-bump the lease forever at 1/3 of the TTL, until killed. Runs in a task for the
  # lifetime of `callable`; transient bump failures are swallowed so a DB hiccup
  # can't tear down the VM — the next tick retries.
  @spec heartbeat(t(), Hyper.Vm.id(), Unit.Time.t()) :: no_return()
  defp heartbeat(img, vm_id, ttl) do
    Process.sleep(div(Unit.Time.as_ms(ttl), 3))

    try do
      _ = Lease.bump(img, vm_id, ttl)
    rescue
      _ -> :ok
    end

    heartbeat(img, vm_id, ttl)
  end
end
