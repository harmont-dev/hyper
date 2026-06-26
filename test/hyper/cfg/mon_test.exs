defmodule Hyper.Cfg.MonTest do
  use ExUnit.Case, async: true

  alias Hyper.Cfg.Mon

  test "default sampling periods stay co-prime per metric" do
    assert Mon.period(:cpu) == Unit.Time.ms(23)
    assert Mon.period(:mem) == Unit.Time.ms(29)
    assert Mon.period(:disk_bw) == Unit.Time.ms(31)
    assert Mon.period(:net_bw) == Unit.Time.ms(37)
  end

  test "default EWMA time constants" do
    assert Mon.tau(:cpu) == Unit.Time.s(30)
    assert Mon.tau(:mem) == Unit.Time.s(30)
    assert Mon.tau(:disk_bw) == Unit.Time.s(20)
    assert Mon.tau(:net_bw) == Unit.Time.s(20)
  end
end
