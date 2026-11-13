defmodule Hyper.Node.KernelGuardPropertiesTest do
  @moduledoc """
  Laws of `KernelGuard`'s exposure rule (exposed iff reachable and not
  provably fixed):

    * mitigation — with nested virtualization confirmed off, or on aarch64, no
      host is exposed to an x86 nested-MMU advisory, whatever its version;
    * no mitigation — a guest-network advisory has no off switch: whatever the
      arch or nested state, only the version decides;
    * no false fix — a version on a branch the advisory never fixed, between
      `introduced` and `mainline`, is never judged fixed;
    * monotonic — on a backported branch, fixed iff `patch >= fixed patch`;
    * unknown is unsafe — an unknown version is never fixed;
    * refusal — unwaived, `evaluate/2` refuses exactly when something is
      exposed, naming every exposed id; waived, it always boots.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog

  alias Hyper.Node.KernelGuard
  alias Hyper.Node.KernelGuard.Host

  defp advisory, do: member_of(KernelGuard.advisories())

  defp version do
    one_of([
      constant(:unknown),
      tuple({integer(2..8), integer(0..30), integer(0..400)})
    ])
  end

  defp host do
    gen all(
          arch <- member_of([:x86_64, :aarch64, :unknown]),
          version <- version(),
          nested <- member_of([true, false, :unknown])
        ) do
      %Host{arch: arch, version: version, nested: nested}
    end
  end

  defp nested_mmu, do: Enum.filter(KernelGuard.advisories(), &(&1.surface == :x86_nested_mmu))
  defp guest_network, do: Enum.filter(KernelGuard.advisories(), &(&1.surface == :guest_network))

  property "nested virt off or aarch64 leaves no host exposed to a nested-MMU advisory" do
    check all(h <- host(), mitigated <- member_of([:nested_off, :aarch64])) do
      h =
        case mitigated do
          :nested_off -> %{h | nested: false}
          :aarch64 -> %{h | arch: :aarch64}
        end

      assert KernelGuard.exposed(h, nested_mmu()) == []
    end
  end

  property "a guest-network advisory is exposed iff the version is not fixed" do
    check all(h <- host(), a <- member_of(guest_network())) do
      assert KernelGuard.exposed(h, [a]) ==
               if(KernelGuard.fixed?(a, h.version), do: [], else: [a])
    end
  end

  property "a branch without a backport is never fixed between introduced and mainline" do
    check all(
            a <- advisory(),
            {maj, min} <- member_of(unfixed_branches(a)),
            patch <- integer(first_patch(a, {maj, min})..400)
          ) do
      refute KernelGuard.fixed?(a, {maj, min, patch})
    end
  end

  # Branches from `introduced` up to (not including) `mainline` with no backport.
  defp unfixed_branches(a) do
    {imaj, imin, _} = a.introduced

    for maj <- 2..7,
        min <- 0..30,
        {maj, min} >= {imaj, imin} and {maj, min} < a.mainline,
        not Map.has_key?(a.fixed_in, {maj, min}),
        do: {maj, min}
  end

  defp first_patch(%{introduced: {maj, min, patch}}, {maj, min}), do: patch
  defp first_patch(_, _), do: 0

  property "on a backported branch, fixed iff patch reaches the fixed patch" do
    check all(
            a <- advisory(),
            {{maj, min}, fixed_patch} <- member_of(Map.to_list(a.fixed_in)),
            patch <- integer(0..(fixed_patch * 2))
          ) do
      assert KernelGuard.fixed?(a, {maj, min, patch}) == patch >= fixed_patch
    end
  end

  property "an unknown version is never fixed" do
    check all(a <- advisory()) do
      refute KernelGuard.fixed?(a, :unknown)
    end
  end

  property "unwaived refuses exactly the exposed ids; waived always boots" do
    check all(h <- host()) do
      ids = h |> KernelGuard.exposed(KernelGuard.advisories()) |> Enum.map(& &1.id)

      capture_log(fn ->
        expected = if ids == [], do: :ok, else: {:error, {:vulnerable_kernel, ids}}
        assert KernelGuard.evaluate(h, false) == expected
        assert KernelGuard.evaluate(h, true) == :ok
      end)
    end
  end

  test "exposure of representative hosts with nesting on" do
    for {version, expected} <- [
          # Ubuntu 24.04: 6.8 never got an upstream backport.
          {{6, 8, 0}, ["CVE-2026-53359", "CVE-2026-64561", "CVE-2026-99999"]},
          {{6, 12, 95}, ["CVE-2026-64561", "CVE-2026-99999"]},
          {{6, 12, 101}, ["CVE-2026-99999"]},
          {{6, 12, 113}, []},
          {{7, 2, 0}, ["CVE-2026-99999"]},
          {{7, 2, 11}, []},
          # Predates Zapscape's 5.9 introduction, but Januscape has no 5.4 fix.
          {{5, 4, 300}, ["CVE-2026-53359", "CVE-2026-99999"]},
          {{2, 6, 26}, []}
        ] do
      host = %Host{arch: :x86_64, version: version, nested: true}
      ids = host |> KernelGuard.exposed(KernelGuard.advisories()) |> Enum.map(& &1.id)
      assert ids == expected, inspect(version)
    end
  end

  test "unconfirmed host facts count against the host" do
    all = Enum.map(KernelGuard.advisories(), & &1.id)
    host = %Host{arch: :unknown, version: :unknown, nested: :unknown}
    assert host |> KernelGuard.exposed(KernelGuard.advisories()) |> Enum.map(& &1.id) == all
  end
end
