defmodule Unit.ScalingPropertiesTest do
  @moduledoc """
  Laws of the binary-prefix constructors and the read-back accessors, which
  `Unit.QuantityPropertiesTest` does not touch (it only exercises the canonical
  bytes / bytes-per-sec / nanosecond constructors through the `Quantity`
  protocol). Every prefix constructor is exact multiplication by a power of 1024
  (1000 for time), and every `as_*` accessor is truncating integer division that
  cancels its own constructor exactly.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Unit.{Bandwidth, Information, Time}

  @kib 1024
  @mib 1024 * @kib
  @gib 1024 * @mib
  @tib 1024 * @gib

  @us 1_000
  @ms 1_000_000
  @s 1_000_000_000

  # Bounded for legible shrink output; Elixir integers are bignums, so the bound
  # is for readability, not to dodge overflow. Signed, to exercise the
  # toward-zero behaviour of the truncating accessors.
  defp scalar, do: integer(-1_000_000..1_000_000)
  defp nonneg, do: integer(0..1_000_000)

  # --- Information -----------------------------------------------------------

  property "Information prefix constructors scale by powers of 1024" do
    check all(v <- scalar()) do
      assert Information.as_bytes(Information.bytes(v)) == v
      assert Information.as_bytes(Information.kib(v)) == v * @kib
      assert Information.as_bytes(Information.mib(v)) == v * @mib
      assert Information.as_bytes(Information.gib(v)) == v * @gib
      assert Information.as_bytes(Information.tib(v)) == v * @tib
    end
  end

  property "each Information prefix is 1024x the one below it" do
    check all(v <- scalar()) do
      assert Information.kib(v * 1024) == Information.mib(v)
      assert Information.mib(v * 1024) == Information.gib(v)
      assert Information.gib(v * 1024) == Information.tib(v)
    end
  end

  property "as_mib / as_gib cancel their own constructor exactly" do
    check all(v <- scalar()) do
      assert Information.as_mib(Information.mib(v)) == v
      assert Information.as_gib(Information.gib(v)) == v
    end
  end

  property "as_mib is truncating division: exact quotient with a bounded remainder" do
    check all(b <- nonneg()) do
      q = Information.as_mib(Information.bytes(b))
      assert q == div(b, @mib)
      assert q * @mib <= b and b < (q + 1) * @mib
    end
  end

  # --- Bandwidth -------------------------------------------------------------

  property "Bandwidth prefix constructors scale by powers of 1024" do
    check all(v <- scalar()) do
      assert Bandwidth.as_bytes_per_sec(Bandwidth.bps(v)) == v
      assert Bandwidth.as_bytes_per_sec(Bandwidth.kibps(v)) == v * @kib
      assert Bandwidth.as_bytes_per_sec(Bandwidth.mibps(v)) == v * @mib
      assert Bandwidth.as_bytes_per_sec(Bandwidth.gibps(v)) == v * @gib
      assert Bandwidth.as_bytes_per_sec(Bandwidth.tibps(v)) == v * @tib
    end
  end

  property "each Bandwidth prefix is 1024x the one below it" do
    check all(v <- scalar()) do
      assert Bandwidth.kibps(v * 1024) == Bandwidth.mibps(v)
      assert Bandwidth.mibps(v * 1024) == Bandwidth.gibps(v)
      assert Bandwidth.gibps(v * 1024) == Bandwidth.tibps(v)
    end
  end

  # --- Time ------------------------------------------------------------------

  property "Time constructors scale to nanoseconds by powers of 1000" do
    check all(v <- scalar()) do
      assert Time.as_ns(Time.ns(v)) == v
      assert Time.as_ns(Time.us(v)) == v * @us
      assert Time.as_ns(Time.ms(v)) == v * @ms
      assert Time.as_ns(Time.s(v)) == v * @s
    end
  end

  property "each Time unit is 1000x the one below it" do
    check all(v <- scalar()) do
      assert Time.ns(v * 1000) == Time.us(v)
      assert Time.us(v * 1000) == Time.ms(v)
      assert Time.ms(v * 1000) == Time.s(v)
    end
  end

  property "as_us / as_ms / as_s cancel their own constructor exactly" do
    check all(v <- scalar()) do
      assert Time.as_us(Time.us(v)) == v
      assert Time.as_ms(Time.ms(v)) == v
      assert Time.as_s(Time.s(v)) == v
    end
  end

  property "as_us is truncating division: exact quotient with a bounded remainder" do
    check all(ns <- nonneg()) do
      q = Time.as_us(Time.ns(ns))
      assert q == div(ns, @us)
      assert q * @us <= ns and ns < (q + 1) * @us
    end
  end
end
