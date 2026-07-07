defmodule Hyper.Metering.UsageTest do
  # Hits the real Postgres image DB; excluded from the default run.
  # Run with: mix test --include external test/hyper/metering/usage_test.exs
  use ExUnit.Case

  @moduletag :external

  alias Hyper.Metering.Usage
  alias Unit.Time

  defp record!(vm_id, start_s, end_s, cpu) do
    base = ~U[2026-07-07 00:00:00.000000Z]

    :ok =
      Usage.record(%{
        vm_id: vm_id,
        node_id: to_string(node()),
        window_start: DateTime.add(base, start_s, :second),
        window_end: DateTime.add(base, end_s, :second),
        cpu_time: cpu
      })
  end

  test "records windows and totals a VM's lifetime compute" do
    vm_id = Hyper.Vm.Id.generate()
    record!(vm_id, 0, 60, Time.ms(1_500))
    record!(vm_id, 60, 120, Time.ms(500))

    assert Time.as_ms(Usage.total(vm_id)) == 2_000
  end

  test "total/3 buckets by window_start over a half-open range" do
    vm_id = Hyper.Vm.Id.generate()
    base = ~U[2026-07-07 00:00:00.000000Z]
    record!(vm_id, 0, 60, Time.ms(100))
    record!(vm_id, 60, 120, Time.ms(200))
    record!(vm_id, 120, 180, Time.ms(400))

    from = DateTime.add(base, 60, :second)
    to = DateTime.add(base, 120, :second)

    # Only the window starting at +60s lands in [from, to).
    assert Time.as_ms(Usage.total(vm_id, from, to)) == 200
  end

  test "consecutive half-open ranges partition the lifetime total" do
    vm_id = Hyper.Vm.Id.generate()
    base = ~U[2026-07-07 00:00:00.000000Z]
    record!(vm_id, 0, 60, Time.ms(100))
    record!(vm_id, 60, 120, Time.ms(200))
    record!(vm_id, 120, 180, Time.ms(400))

    # Cuts land exactly ON window_starts — the case a <=/< mix-up double-counts.
    cuts = Enum.map([0, 60, 120, 121], &DateTime.add(base, &1, :second))

    part_sum =
      cuts
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> Time.as_ms(Usage.total(vm_id, from, to)) end)
      |> Enum.sum()

    assert part_sum == Time.as_ms(Usage.total(vm_id))
  end

  test "a retried flush for the same window is dropped, not double-billed" do
    vm_id = Hyper.Vm.Id.generate()
    record!(vm_id, 0, 60, Time.ms(1_000))
    # Same (vm_id, window_start): a retry whose first attempt committed.
    record!(vm_id, 0, 90, Time.ms(1_500))

    assert Time.as_ms(Usage.total(vm_id)) == 1_000
  end

  test "an unmetered VM totals nil, and zero windows are refused" do
    vm_id = Hyper.Vm.Id.generate()
    assert Usage.total(vm_id) == nil

    assert {:error, %Ecto.Changeset{}} =
             Usage.record(%{
               vm_id: vm_id,
               node_id: to_string(node()),
               window_start: DateTime.utc_now(),
               window_end: DateTime.utc_now(),
               cpu_time: Time.zero()
             })
  end
end
