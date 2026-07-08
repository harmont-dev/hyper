defmodule Sys.MonTest do
  @moduledoc """
  Live contract of the monitor stack, driven against the app's own running
  monitors (started under `Hyper.Node.Budget.Supervisor`):

    * `readings/0` answers with all four metrics as `Server.Reading` structs —
      proving every monitor is registered under its module name and alive;
    * forcing real samples on each monitor yields a domain-typed instant:
      CPU a fraction in `0.0..1.0`, memory a positive `Unit.Information`,
      disk/net a non-negative `Unit.Bandwidth` — exercising the real
      `/proc` + `/sys` read paths end-to-end.

  Two forced samples are taken where the first may only establish a rate/delta
  baseline (`:skip`), with a short sleep in between so the bandwidth monitors'
  `Controls.Rate` sees a positive dt. Not async: the monitors are shared,
  name-registered processes.
  """
  use ExUnit.Case, async: false

  # Needs the app's real supervision tree (the monitors are name-registered
  # children of Hyper.Node.Budget.Supervisor), which the default `--no-start`
  # unit run never boots — this is KVM-job territory, like the other live
  # contracts.
  @moduletag :integration

  alias Sys.Mon
  alias Sys.Mon.{Cpu, DiskBw, Mem, NetBw, Server}
  alias Sys.Mon.Server.Reading
  alias Unit.{Bandwidth, Information}

  test "readings/0 answers for all four metrics" do
    assert %Mon.Readings{
             cpu: %Reading{},
             mem: %Reading{},
             disk_bw: %Reading{},
             net_bw: %Reading{}
           } = Mon.readings()
  end

  test "forced CPU samples yield a busy fraction within 0.0..1.0" do
    _baseline = Server.sample_now(Cpu)
    assert %Reading{instant: u} = Server.sample_now(Cpu)
    assert is_float(u)
    assert u >= 0.0 and u <= 1.0
  end

  test "a forced memory sample reports positive used memory" do
    assert %Reading{instant: %Information{} = used} = Server.sample_now(Mem)
    assert Information.as_bytes(used) > 0
  end

  test "forced disk samples yield a non-negative bandwidth" do
    _baseline = Server.sample_now(DiskBw)
    Process.sleep(5)
    assert %Reading{instant: %Bandwidth{} = bw} = Server.sample_now(DiskBw)
    assert Bandwidth.as_bytes_per_sec(bw) >= 0
  end

  test "forced net samples yield a non-negative bandwidth" do
    _baseline = Server.sample_now(NetBw)
    Process.sleep(5)
    assert %Reading{instant: %Bandwidth{} = bw} = Server.sample_now(NetBw)
    assert Bandwidth.as_bytes_per_sec(bw) >= 0
  end
end
