defmodule Hyper.MixProject do
  use Mix.Project

  def project do
    [
      app: :hyper,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      name: "Hyper",
      source_url: "https://github.com/harmont-dev/hyper",
      # Generate the (gitignored) Firecracker bindings before the Elixir compiler.
      # A Mix compiler (not a `compile` alias) is used because Mix honors a
      # dependency's `:compilers` but NOT its aliases or `config/` -- so this is
      # the only hook that also fires when hyper is compiled AS A DEPENDENCY.
      compilers: [:suidhelper_stamp, :firecracker_gen, :grpc_gen | Mix.compilers()],
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      docs: docs(),
      package: package(),
      aliases: aliases(),
      dialyzer: [
        # Cache the PLTs in a stable, gitignored dir so CI can cache them.
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        # Verify @specs against actual returns, and flag ignored return values.
        flags: [:unmatched_returns, :extra_return, :missing_return]
      ]
    ]
  end

  # Run the coverage tasks in :test so test-only deps (excoveralls) load and the
  # Repo-backed tests see the test database. Mirrors how `mix test` selects :test.
  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.json": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Hyper.Application, []},
      # ecto_repos lives here (not config.exs) since it's well-known and
      # compile-time fixed. Mix's ecto.* tasks read it from the app env.
      env: [ecto_repos: [Hyper.Img.Db.Repo]]
    ]
  end

  # `test/support` holds test-only helpers (e.g. the Redist HTTP test server);
  # compile it only in :test so it never ships in dev/prod builds.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.0", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:junit_formatter, "~> 3.4", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Syntect-backed Makeup lexer: covers the doc languages that have no
      # dedicated Makeup lexer (markdown, toml, bash, sh, python). Elixir/erlang
      # still use their native lexers; this fills the rest in one dep.
      {:makeup_syntect, "~> 0.1", only: :dev, runtime: false},
      {:ecto_sql, "~> 3.13"},
      {:grpc, "~> 1.0"},
      {:grpc_server, "~> 1.0"},
      {:horde, "~> 0.9"},
      {:jason, "~> 1.4"},
      {:libcluster, "~> 3.3"},
      {:muontrap, "~> 1.5"},
      {:open_telemetry_decorator, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:postgrex, "~> 0.20"},
      {:protobuf, "~> 0.17"},
      {:req, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:uuidv4, "~> 1.0"},
      # Not `only: :dev`: the generated Firecracker bindings are gitignored and
      # produced by the `:firecracker_gen` Mix compiler, which runs wherever hyper
      # is compiled -- including as a dependency of another app, where Mix won't
      # load hyper's `config/` or aliases. So the generator must be available in
      # every env that compiles hyper (deps included). `runtime: false` keeps it
      # compile-only and out of releases.
      {:oapi_generator, "~> 0.4.0", runtime: false}
    ]
  end

  # ExDoc config - drives `mix docs` and what HexDocs renders.
  defp docs do
    [
      # Landing page of the docs site.
      main: "readme",
      # Inject Mermaid so ```mermaid fences in docs render as diagrams.
      before_closing_body_tag: &before_closing_body_tag/1,
      # Narrative/guide pages rendered alongside the API reference.
      extras: [
        "README.md",
        "docs/cookbook/intro.md",
        "docs/cookbook/install.md",
        "docs/cookbook/config.md",
        "docs/cookbook/architecture.md",
        "docs/grpc.md"
      ],
      groups_for_extras: [
        Cookbook: ~r/docs\/cookbook\/.*/
      ],
      # Group modules in the sidebar by namespace. Each value is a regex matched
      # against the module name, so new modules join their group automatically --
      # no per-module edits here. The patterns are mutually exclusive, so the
      # listing order is purely cosmetic. (`Sys.Mon.*` -> Monitoring; every other
      # `Sys.Posix`/`Sys.Linux.*`, including the /proc parsers, -> System.)
      groups_for_modules: [
        VM: ~r/^Hyper\.Vm(\.|$)/,
        Node: ~r/^Hyper\.Node(\.|$)/,
        Images: ~r/^Hyper\.(Img|Layer)(\.|$)/,
        Controls: ~r/^Controls\./,
        Monitoring: ~r/^Sys\.Mon(\.|$)/,
        System: ~r/^(Sys\.|Hyper\.SuidHelper$)/,
        Units: ~r/^Unit\./
      ]
    ]
  end

  # Load Mermaid in the HTML docs and render any ```mermaid code fences as
  # diagrams. ExDoc tags Mermaid blocks with the `mermaid` class.
  defp before_closing_body_tag(:html) do
    """
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css" crossorigin="anonymous">
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js" crossorigin="anonymous"></script>
    <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js" crossorigin="anonymous"
    onload="renderMathInElement(document.body, {delimiters: [
      {left: '$$', right: '$$', display: true},
      {left: '$', right: '$', display: false},
      {left: '\\\\[', right: '\\\\]', display: true},
      {left: '\\\\(', right: '\\\\)', display: false}
    ]});"></script>
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js" integrity="sha384-rbtjAdnIQE/aQJGEgXrVUlMibdfTSa4PQju4HDhN3sR2PmaKFzhEafuePsl9H/9I" crossorigin="anonymous"></script>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({
          startOnLoad: false,
          theme: document.body.className.includes("dark") ? "dark" : "default"
        });
        let id = 0;
        for (const pre of document.querySelectorAll("pre.mermaid")) {
          const code = pre.textContent;
          const div = document.createElement("div");
          div.className = "mermaid";
          div.textContent = code;
          pre.replaceWith(div);
        }
        mermaid.run();
      });
    </script>
    """
  end

  defp before_closing_body_tag(_), do: ""

  # Hex package metadata. Required for `mix hex.publish`.
  defp package do
    [
      description: "A distributed orchestrator for Firecracker microVMs.",
      # The OTP app is `:hyper`, but `hyper` is already taken on Hex, so the
      # package publishes as `hypervm`. Package name and app name are independent.
      name: "hypervm",
      licenses: ["AGPL-3.0-or-later"],
      # priv/firecracker ships the OpenAPI spec so the `:firecracker_gen` compiler
      # can regenerate the bindings in a consumer's build (they are gitignored, so
      # not in `lib`).
      # proto/ ships the gRPC contract so the `:grpc_gen` compiler can regenerate
      # the bindings in a consumer's build (they are gitignored, not in `lib`).
      files: ~w(lib priv/firecracker proto config mix.exs README.md LICENSE NOTICE CLA.md),
      links: %{"GitHub" => "https://github.com/harmont-dev/hyper"}
    ]
  end

  # `mix check` - the strict gate. Runs fast checks first, slow ones (dialyzer) last.
  # Give ```bash / ```sh real syntax highlighting in the docs.
  #
  # Two obstacles, both about *who registers the lexer last*:
  #   1. makeup_syntect registers the shell grammar only under its raw syntect
  #      name "Shell-Unix-Generic" (ExDoc resolves fences by lexer name, not
  #      file extension), so ```bash / ```sh never reach it.
  #   2. ExDoc itself registers a minimal `ExDoc.ShellLexer` for sh/bash/shell/
  #      zsh (it only de-selects the `$ ` prompt; everything else is plain text)
  #      from `ExDoc.Application.start`, which runs during the `docs` task.
  #
  # So we start :ex_doc and :makeup_syntect here first (idempotent — the later
  # `docs` task won't re-run their `start/2`), then register our shell aliases
  # LAST so they win. Dev-only; runs as the `docs` alias's first step.
  defp register_doc_lexers(_args) do
    {:ok, _} = Application.ensure_all_started(:makeup_syntect)
    {:ok, _} = Application.ensure_all_started(:ex_doc)

    Makeup.Registry.register_lexer(MakeupSyntect.Lexer,
      options: [language: "Shell-Unix-Generic"],
      names: ["bash", "sh", "shell", "zsh"],
      extensions: []
    )

    :ok
  end

  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test --warnings-as-errors",
        "dialyzer"
      ],
      # makeup_syntect registers the shell grammar only under its raw syntect
      # name "Shell-Unix-Generic", and ExDoc resolves fences by lexer *name*
      # (not file extension), so ```bash / ```sh would fall back to plain text.
      # Alias them to the shell grammar before ExDoc runs (same VM, so the
      # registration is visible to the highlighter).
      docs: ["loadpaths", &register_doc_lexers/1, "docs"],
      # Force a regeneration of the Firecracker bindings (ignores staleness).
      "firecracker.gen": ["compile.firecracker_gen --force"],
      # Force a regeneration of the gRPC bindings (ignores staleness).
      "grpc.gen": ["compile.grpc_gen --force"],
      # Rebuild + stamp the suidhelper and re-capture its expected identity.
      "suidhelper.stamp": ["compile.suidhelper_stamp --force"]
    ]
  end
end

defmodule Mix.Tasks.Compile.GrpcGen do
  @moduledoc """
  Mix compiler that generates the gRPC bindings into
  `lib/hyper/grpc/v0/hyper.pb.ex` from `proto/hyper/grpc/v0/hyper.proto`, just
  before the Elixir compiler. Like the Firecracker bindings, the output is
  gitignored and regenerated rather than committed.

  Defined in `mix.exs` (not under `lib/`) so it is loaded before any
  compilation. Unlike the Firecracker generator (pure-Elixir `oapi_generator`),
  this shells out to `protoc` with the `protoc-gen-elixir` plugin, so both must
  be installed in any environment that compiles hyper from a fresh tree:

      sudo apt-get install -y protobuf-compiler   # or: brew install protobuf
      mix escript.install hex protobuf 0.17.0     # provides protoc-gen-elixir

  The plugin escript lives in `~/.mix/escripts`, which this compiler prepends to
  `PATH` for the `protoc` invocation. The generated file is `mix format`-ed so it
  passes the formatting gate.
  """

  use Mix.Task.Compiler

  @proto "proto/hyper/grpc/v0/hyper.proto"
  @proto_path "proto/hyper/grpc/v0"
  @out "lib/hyper/grpc/v0/hyper.pb.ex"

  @impl Mix.Task.Compiler
  def run(argv) do
    if "--force" in argv or stale?() do
      generate()
    end

    {:ok, []}
  end

  defp generate do
    File.mkdir_p!(Path.dirname(@out))
    escripts = Path.expand("~/.mix/escripts")
    env = [{"PATH", escripts <> ":" <> System.get_env("PATH", "")}]

    args = ["--proto_path=#{@proto_path}", "--elixir_out=plugins=grpc:lib", "hyper.proto"]

    case System.cmd("protoc", args, env: env, stderr_to_stdout: true) do
      {_, 0} ->
        # protoc-gen-elixir mirrors the package path under the output dir, so the
        # file lands exactly at @out. Format it to satisfy the formatting gate.
        Mix.Task.run("format", [@out])

      {output, code} ->
        Mix.raise("""
        protoc failed (exit #{code}) generating #{@out}:

        #{output}
        Ensure `protoc` and the `protoc-gen-elixir` escript are installed:
            sudo apt-get install -y protobuf-compiler
            mix escript.install hex protobuf 0.17.0
        """)
    end
  end

  defp stale? do
    not File.exists?(@out) or File.stat!(@proto).mtime > File.stat!(@out).mtime
  end
end

defmodule Mix.Tasks.Compile.FirecrackerGen do
  @moduledoc """
  Mix compiler that generates the Firecracker API bindings into
  `lib/hyper/firecracker/api/{operations,schemas}` from the committed OpenAPI
  spec, just before the Elixir compiler.

  Defined in `mix.exs` (not under `lib/`) so it is loaded before any compilation
  and is available even when hyper is built as a dependency -- Mix honors a
  dependency's `:compilers` but neither its `config/` nor its aliases, so the
  generator config is supplied here via `Application.put_env/3` rather than
  `config/config.exs`.

  The committed spec is OpenAPI 3, converted from Firecracker's upstream Swagger
  2.0 (not vendored). To bump the version, fetch the new tag's spec and convert,
  then point `@spec_path` at it and run `mix firecracker.gen`:

      curl -fsSL https://raw.githubusercontent.com/firecracker-microvm/firecracker/vX.Y.Z/src/firecracker/swagger/firecracker.yaml \\
      | curl -fsS -X POST https://converter.swagger.io/api/convert \\
          -H 'Content-Type: application/yaml' -H 'Accept: application/json' --data-binary @- \\
          -o priv/firecracker/firecracker-vX.Y.Z.openapi.json
  """

  use Mix.Task.Compiler

  @spec_path "priv/firecracker/firecracker-v1.16.0.openapi.json"
  @out "lib/hyper/firecracker/api/operations/operations.ex"

  @config [
    output: [
      base_module: Hyper.Firecracker.Api,
      location: "lib/hyper/firecracker/api",
      default_client: Hyper.Firecracker.Api.Transport,
      operation_subdirectory: "operations",
      schema_subdirectory: "schemas",
      schema_use: Hyper.Firecracker.Api.Codec,
      extra_fields: [__info__: :any],
      field_casing: :snake,
      types: [specs: :spec]
    ],
    naming: [
      default_operation_module: Operations,
      operation_use_tags: false
    ]
  ]

  @impl Mix.Task.Compiler
  def run(argv) do
    if "--force" in argv or stale?() do
      Mix.Task.run("loadpaths")
      Application.put_env(:oapi_generator, :default, @config)
      OpenAPI.run("default", [@spec_path])
    end

    {:ok, []}
  end

  defp stale? do
    not File.exists?(@out) or File.stat!(@spec_path).mtime > File.stat!(@out).mtime
  end
end

defmodule Mix.Tasks.Compile.SuidhelperStamp do
  @moduledoc """
  Mix compiler that builds and stamps the Rust setuid helper, then captures the
  build identity it will report at runtime into a generated module,
  `Hyper.SuidHelper.Expected` (gitignored, like the other generated bindings).

  Steps, run before the Elixir compiler so the generated module compiles:

    1. `cargo xtask stamp` (in `native/suidhelper`) builds the release binary and
       writes its BLAKE3 self-checksum into the ELF `.note.sum` section.
    2. The stamped binary's `version` subcommand is invoked; its JSON
       (`{"version":..,"checksum_blake3":..}`) is the helper's self-reported
       build identity.
    3. Its version + checksum are baked into `lib/hyper/suid_helper/expected.ex`
       so the BEAM can compare a deployed helper against the one this build made.

  Always runs (no staleness gate): `cargo` is incremental, so a no-op rebuild is
  cheap, and this keeps the embedded identity in lockstep with the binary. Like
  the protoc compiler, a missing toolchain is a hard failure -- `cargo` and the
  helper's nightly toolchain must be present wherever hyper is compiled.

  Note: the checksum is *self-reported* by the binary, so the generated module is
  a build-provenance / version-skew check, not an adversarial tamper proof (a
  malicious binary could print any value). Real tamper detection would re-hash
  the on-disk ELF with `.note.sum` zeroed and compare -- the embedded checksum is
  the reference value that check would use.
  """

  use Mix.Task.Compiler

  @helper_dir "native/suidhelper"
  @binary "native/suidhelper/target/release/hyper-suidhelper"
  @out "lib/hyper/suid_helper/expected.ex"

  @impl Mix.Task.Compiler
  def run(_argv) do
    stamp!()
    json = capture_version!()
    generate(json)
    {:ok, []}
  end

  defp stamp! do
    case System.cmd("cargo", ["xtask", "stamp"], cd: @helper_dir, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Mix.raise("""
        `cargo xtask stamp` failed (exit #{code}) building the suidhelper:

        #{output}
        Ensure `cargo` and the helper's toolchain (see #{@helper_dir}/rust-toolchain.toml)
        are installed.
        """)
    end
  end

  defp capture_version! do
    case System.cmd(Path.expand(@binary), ["version"], stderr_to_stdout: true) do
      {out, 0} ->
        String.trim(out)

      {out, code} ->
        Mix.raise("`hyper-suidhelper version` failed (exit #{code}): #{out}")
    end
  end

  defp generate(json) do
    # Jason and the app's deps are available once loadpaths runs.
    Mix.Task.run("loadpaths")
    %{"version" => version, "checksum_blake3" => checksum} = Jason.decode!(json)

    File.mkdir_p!(Path.dirname(@out))

    source = """
    defmodule Hyper.SuidHelper.Expected do
      @moduledoc false
      # GENERATED by Mix.Tasks.Compile.SuidhelperStamp from the stamped
      # `hyper-suidhelper version` output. Do not edit; gitignored.

      @version #{inspect(version)}
      @checksum_blake3 #{inspect(checksum)}

      @doc "Expected helper version."
      @spec version() :: String.t()
      def version, do: @version

      @doc "Expected BLAKE3 checksum (hex) of the stamped helper."
      @spec checksum_blake3() :: String.t()
      def checksum_blake3, do: @checksum_blake3
    end
    """

    # Format the generated source directly rather than via `Mix.Task.run("format",
    # ...)`: a Mix task runs once per session, so invoking it here would consume
    # the single run and leave the later `:grpc_gen` compiler's format a no-op.
    File.write!(@out, [Code.format_string!(source), "\n"])
  end
end
