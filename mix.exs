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
      {:uuidv4, "~> 1.0"}
    ]
  end

  # ExDoc config — drives `mix docs` and what HexDocs renders.
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
      # Group modules in the sidebar so the API reference is navigable.
      groups_for_modules: [
        VM: [Hyper.VM, Hyper.VM.Instance, Hyper.VM.Instance.Spec],
        Node: [
          Hyper.Node,
          Hyper.Node.FireVMM,
          Hyper.Node.FireVMM.Jailer,
          Hyper.Node.FireVMM.State,
          Hyper.Node.Img,
          Hyper.Node.Img.Server,
          Hyper.Node.Layer,
          Hyper.Node.Layer.Repo,
          Hyper.Node.Layer.Server,
          Hyper.Node.Users
        ],
        Images: [
          Hyper.Img,
          Hyper.Img.DB.Blob,
          Hyper.Img.DB.Image,
          Hyper.Img.DB.ImageLayer,
          Hyper.Img.DB.Lease,
          Hyper.Img.DB.Repo,
          Hyper.Layer
        ],
        System: [
          Hyper.SuidHelper,
          Hyper.Sys.Posix,
          Hyper.Sys.Linux.Cgroup,
          Hyper.Sys.Linux.Cgroup.V2,
          Hyper.Sys.Linux.Dmsetup,
          Hyper.Sys.Linux.Fstab,
          Hyper.Sys.Linux.Losetup,
          Hyper.Sys.Linux.Nss,
          Hyper.Sys.Linux.Proc.Mounts,
          Hyper.Sys.Linux.Subid
        ],
        Units: [Unit.Time, Unit.Information, Unit.Bandwidth]
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

  # `mix check` — the strict gate. Runs fast checks first, slow ones (dialyzer) last.
  defp aliases do
    [
      check: [
        "format --check-formatted",
        "compile --warnings-as-errors --force",
        "credo --strict",
        "test --warnings-as-errors",
        "dialyzer"
      ]
    ]
  end
end
