defmodule Hyper.MixProject do
  use Mix.Project

  def project do
    [
      app: :hyper,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      name: "Hyper",
      source_url: "https://github.com/harmont-dev/hyper",
      # Generate the (gitignored) Firecracker bindings before the Elixir compiler.
      # A Mix compiler (not a `compile` alias) is used because Mix honors a
      # dependency's `:compilers` but NOT its aliases or `config/` -- so this is
      # the only hook that also fires when hyper is compiled AS A DEPENDENCY.
      compilers: [:firecracker_gen | Mix.compilers()],
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.17"},
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
        "docs/cookbook/architecture.md"
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
      # The OTP app is `:hyper`, but `hyper` is already taken on Hex, so the
      # package publishes as `hypervm`. Package name and app name are independent.
      name: "hypervm",
      licenses: ["AGPL-3.0-or-later"],
      # priv/firecracker ships the OpenAPI spec so the `:firecracker_gen` compiler
      # can regenerate the bindings in a consumer's build (they are gitignored, so
      # not in `lib`).
      files: ~w(lib priv/firecracker config mix.exs README.md LICENSE NOTICE CLA.md),
      links: %{"GitHub" => "https://github.com/harmont-dev/hyper"}
    ]
  end

  # `mix check` - the strict gate. Runs fast checks first, slow ones (dialyzer) last.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test --warnings-as-errors",
        "dialyzer"
      ],
      # Force a regeneration of the Firecracker bindings (ignores staleness).
      "firecracker.gen": ["compile.firecracker_gen --force"]
    ]
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
