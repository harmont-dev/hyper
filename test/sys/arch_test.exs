defmodule Sys.ArchTest do
  @moduledoc """
  Laws of the architecture classifier:

    * **Marker detection** — any string carrying a known marker (`x86_64`,
      `amd64`, `aarch64`, `arm64`) parses to that architecture, wherever the
      marker sits in the string.
    * **Refusal** — a string carrying no marker is refused with
      `{:unsupported_arch, raw}`, echoing the raw input for the error report.
    * **goarch inverse** — `goarch/1` emits the Go/OCI name, which is itself a
      marker `parse/1` recognizes: `parse(goarch(a)) == {:ok, a}`.
    * Examples pin real target triplets, and `current/0` must succeed on any
      machine the suite runs on (CI hosts are supported architectures).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Arch

  # Surrounding text that cannot itself form a marker: markers are lowercase
  # letters + digits, so uppercase-and-dash filler is inert.
  defp filler, do: string([?A..?Z, ?-], max_length: 8)

  property "any string carrying a known marker parses to its architecture" do
    markers = [
      {"x86_64", :x86_64},
      {"amd64", :x86_64},
      {"aarch64", :aarch64},
      {"arm64", :aarch64}
    ]

    check all(
            {marker, arch} <- member_of(markers),
            pre <- filler(),
            post <- filler()
          ) do
      assert Arch.parse(pre <> marker <> post) == {:ok, arch}
    end
  end

  property "a string with no marker is refused, echoing the raw string" do
    check all(raw <- string([?A..?Z, ?-, ?\s], max_length: 20)) do
      assert Arch.parse(raw) == {:error, {:unsupported_arch, raw}}
    end
  end

  test "parses real target triplets" do
    cases = [
      {"x86_64-pc-linux-gnu", :x86_64},
      {"x86_64-unknown-linux-musl", :x86_64},
      {"amd64-portbld-freebsd14.0", :x86_64},
      {"aarch64-unknown-linux-gnu", :aarch64},
      {"arm64-apple-darwin24.0.0", :aarch64}
    ]

    for {sys, expected} <- cases do
      assert Arch.parse(sys) == {:ok, expected}, sys
    end
  end

  test "current/0 succeeds on this machine with a supported architecture" do
    assert {:ok, arch} = Arch.current()
    assert arch in [:x86_64, :aarch64]
  end

  property "goarch is a right inverse of parse for every supported architecture" do
    check all(arch <- member_of([:x86_64, :aarch64])) do
      assert Arch.parse(Arch.goarch(arch)) == {:ok, arch}
    end
  end

  test "goarch emits the Go/OCI names skopeo expects" do
    assert Arch.goarch(:x86_64) == "amd64"
    assert Arch.goarch(:aarch64) == "arm64"
  end
end
