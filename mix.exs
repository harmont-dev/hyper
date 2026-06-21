defmodule Hyper.MixProject do
  use Mix.Project

  def project do
    [
      app: :hyper,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      name: "Hyper",
      source_url: "https://github.com/harmont-dev/hyper",
      deps: deps(),
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
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:ecto_sql, "~> 3.13"},
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
      {:uuidv4, "~> 1.0"},
      # Not `only: :dev`: the generated Firecracker bindings are gitignored and
      # (re)generated before `compile` in every env (see `gen_firecracker/1`),
      # so the generator must be available wherever the app compiles.
      # `runtime: false` still keeps it out of releases.
      {:oapi_generator, "~> 0.4.0", runtime: false}
    ]
  end

  # Firecracker API bindings are generated from the committed OpenAPI spec and
  # are NOT checked in. `gen_firecracker/1` runs before `compile` (see aliases)
  # and (re)generates them whenever the spec is newer than the last output.
  @firecracker_spec "priv/firecracker/firecracker-v1.16.0.openapi.json"
  @firecracker_out "lib/hyper/firecracker/api/operations/operations.ex"

  defp gen_firecracker(_args) do
    if firecracker_stale?() do
      Mix.Task.run("loadpaths")
      OpenAPI.run("default", [@firecracker_spec])
    end

    :ok
  end

  defp firecracker_stale? do
    not File.exists?(@firecracker_out) or
      File.stat!(@firecracker_spec).mtime > File.stat!(@firecracker_out).mtime
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
      licenses: ["AGPL-3.0-or-later"],
      files: ~w(lib config mix.exs README.md LICENSE NOTICE CLA.md),
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
      # Generate the (gitignored) Firecracker bindings before every compile.
      # Re-entrant: the trailing "compile" runs the real compiler task.
      compile: [&gen_firecracker/1, "compile"],
      # Manual/forced regeneration: `mix firecracker.gen`.
      "firecracker.gen": [&gen_firecracker/1]
    ]
  end
end
