defmodule Hyper.Sys.Unit do
  @moduledoc "Conversion utilities"

  defmodule Binary do
    @moduledoc false

    def kibi(val), do: 1024 * val
    def mebi(val), do: 1024 * kibi(val)
    def gibi(val), do: 1024 * mebi(val)
    def tebi(val), do: 1024 * gibi(val)
  end

  defmodule SI do
    @moduledoc false

    def nano(val), do: micro(val) * 10
    def micro(val), do: milli(val) * 10
    def milli(val), do: centi(val) * 10
    def centi(val), do: deci(val) * 10
    def deci(val), do: val * 10
    # -- base
    def deca(val), do: val / 10
    def hecto(val), do: deca(val) / 10
    def kilo(val), do: hecto(val) / 10
    def mega(val), do: kilo(val) / 10
    def giga(val), do: mega(val) / 10
    def tera(val), do: giga(val) / 10
  end

  defmodule Bytes do
    @moduledoc false

    defdelegate kib(val), to: Binary, as: :kibi
    defdelegate mib(val), to: Binary, as: :mebi
    defdelegate gib(val), to: Binary, as: :gibi
    defdelegate tib(val), to: Binary, as: :tebi
  end

  defmodule Bw do
    @moduledoc false

    defdelegate kibps(val), to: Binary, as: :kibi
    defdelegate mibps(val), to: Binary, as: :mebi
    defdelegate gibps(val), to: Binary, as: :gibi
    defdelegate tibps(val), to: Binary, as: :tebi
  end
end
