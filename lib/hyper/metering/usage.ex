defmodule Hyper.Metering.Usage do
  @moduledoc """
  One VM's metered compute over one wall-clock window: `cpu_usec` is CPU time
  the VM *actually executed* between `window_start` and `window_end`, measured
  from its cgroup's `cpu.stat` by `Hyper.Node.FireVMM.Meter`.

  Append-only: one row per VM per flush window (plus a final row at teardown),
  never updated. Windows with zero consumption are not recorded — absence of
  rows over a span means no compute happened. Billing reads `total/1` (a VM's
  lifetime compute) or `total/3` (compute over a half-open `[from, to)` range,
  bucketed by `window_start` so consecutive ranges never double-count).

  Stored in the cluster's shared Postgres via `Hyper.Img.Db.Repo` — usage
  rows have no foreign keys so a billing record outlives the VM, its image,
  and its lease.
  """
  use Ecto.Schema
  use OpenTelemetryDecorator

  import Ecto.Changeset
  import Ecto.Query

  alias Hyper.Img.Db.Repo
  alias Unit.Time

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "vm_usage" do
    field :node_id, :string
    field :vm_id, :string
    field :window_start, :utc_datetime_usec
    field :window_end, :utc_datetime_usec
    field :cpu_usec, :integer

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type attrs :: %{
          vm_id: Hyper.Vm.Id.t(),
          node_id: String.t(),
          window_start: DateTime.t(),
          window_end: DateTime.t(),
          cpu_time: Time.t()
        }

  @doc "Record one usage window. Zero-consumption windows are refused, not stored."
  @spec record(attrs()) :: :ok | {:error, Ecto.Changeset.t()}
  @decorate with_span("Hyper.Metering.Usage.record", include: [:vm_id])
  def record(%{vm_id: vm_id, cpu_time: cpu_time} = attrs) do
    changeset =
      %__MODULE__{}
      |> cast(
        %{
          vm_id: vm_id,
          node_id: attrs.node_id,
          window_start: attrs.window_start,
          window_end: attrs.window_end,
          cpu_usec: Time.as_us(cpu_time)
        },
        [:vm_id, :node_id, :window_start, :window_end, :cpu_usec]
      )
      |> validate_required([:vm_id, :node_id, :window_start, :window_end, :cpu_usec])
      |> validate_number(:cpu_usec, greater_than: 0)

    with {:ok, _row} <- Repo.insert(changeset), do: :ok
  end

  @doc "A VM's lifetime metered compute; `nil` when the VM was never metered."
  @spec total(Hyper.Vm.Id.t()) :: Time.t() | nil
  @decorate with_span("Hyper.Metering.Usage.total", include: [:vm_id])
  def total(vm_id) do
    from(u in __MODULE__, where: u.vm_id == ^vm_id, select: sum(u.cpu_usec))
    |> Repo.one()
    |> to_time()
  end

  @doc """
  A VM's metered compute across windows starting in `[from, to)`; `nil` when
  none do. A window straddling `to` counts whole — usage is bucketed by
  `window_start`, so consecutive ranges never double-count.
  """
  @spec total(Hyper.Vm.Id.t(), DateTime.t(), DateTime.t()) :: Time.t() | nil
  @decorate with_span("Hyper.Metering.Usage.total", include: [:vm_id])
  def total(vm_id, from, to) do
    from(u in __MODULE__,
      where: u.vm_id == ^vm_id and u.window_start >= ^from and u.window_start < ^to,
      select: sum(u.cpu_usec)
    )
    |> Repo.one()
    |> to_time()
  end

  # Postgres SUM(bigint) comes back as a Decimal (or nil when no rows matched).
  @spec to_time(Decimal.t() | nil) :: Time.t() | nil
  defp to_time(nil), do: nil
  defp to_time(%Decimal{} = sum), do: Time.us(Decimal.to_integer(sum))
end
