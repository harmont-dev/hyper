defmodule Redist.Support.HttpServer do
  @moduledoc """
  Ephemeral localhost file server for Redist download tests, backed by OTP's
  bundled `:inets`/`:httpd` (no extra deps). It serves the files written under a
  per-test document root over `http://127.0.0.1:<port>/...`, so the download
  tests exercise the real `Req` streaming path end to end instead of a mock.

  `start/0` must be called from a test process: it registers an `on_exit/1`
  callback that stops the server and deletes its temp directory.
  """

  @spec start() :: %{base_url: String.t(), docroot: Path.t()}
  def start do
    {:ok, _} = Application.ensure_all_started(:inets)

    tmp = Path.join(System.tmp_dir!(), "redist-httpd-#{System.unique_integer([:positive])}")
    docroot = Path.join(tmp, "docroot")
    File.mkdir_p!(docroot)

    {:ok, pid} =
      :inets.start(:httpd,
        port: 0,
        bind_address: ~c"127.0.0.1",
        # Unique per instance so concurrent (async) test servers never collide.
        server_name: ~c"redist-test-#{System.unique_integer([:positive])}",
        server_root: String.to_charlist(tmp),
        document_root: String.to_charlist(docroot),
        mime_types: [
          {~c"gz", ~c"application/gzip"},
          {~c"tgz", ~c"application/gzip"},
          {~c"bin", ~c"application/octet-stream"},
          {~c"txt", ~c"text/plain"}
        ]
      )

    port = :httpd.info(pid)[:port]

    ExUnit.Callbacks.on_exit(fn ->
      :inets.stop(:httpd, pid)
      File.rm_rf!(tmp)
    end)

    %{base_url: "http://127.0.0.1:#{port}", docroot: docroot}
  end

  @spec put_file(
          %{required(:base_url) => String.t(), required(:docroot) => Path.t()},
          String.t(),
          binary()
        ) ::
          String.t()
  def put_file(%{base_url: base, docroot: docroot}, name, contents) do
    path = Path.join(docroot, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    "#{base}/#{name}"
  end

  @spec missing_url(%{required(:base_url) => String.t()}, String.t()) :: String.t()
  def missing_url(%{base_url: base}, name), do: "#{base}/#{name}"
end
