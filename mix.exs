defmodule CodetracerBeamRecorder.MixProject do
  use Mix.Project

  @version "0.1.0"
  @repo_url "https://github.com/metacraft-labs/codetracer-beam-recorder"

  def project do
    [
      app: :codetracer_beam_recorder,
      version: @version,
      elixir: "~> 1.15",
      build_embedded: false,
      start_permanent: false,
      description: description(),
      package: package(),
      source_url: @repo_url,
      homepage_url: @repo_url,
      deps: deps()
    ]
  end

  # `:plug` is optional: `CodetracerBeamRecorder.Plug` (RS-M8 web-request
  # spans) is compiled against it, and every other part of the package —
  # the mix tasks, the source map, the Erlang runtime app — works without a
  # web framework anywhere in sight.  Marking it optional means a plain
  # Elixir project that only wants `mix codetracer.record` does not pull in
  # Plug, while a Plug or Phoenix project already has it.
  defp deps do
    [
      {:plug, "~> 1.14", optional: true}
    ]
  end

  defp description do
    "CodeTracer BEAM materialized trace recorder (Erlang and Elixir). " <>
      "Records BEAM-targeted programs into the CodeTracer CTFS trace bundle " <>
      "format and integrates with Mix and Rebar3."
  end

  defp package do
    [
      name: "codetracer_beam_recorder",
      maintainers: ["Metacraft Labs"],
      licenses: ["Apache-2.0"],
      files: [
        "lib",
        "apps/codetracer_erlang_runtime",
        "mix.exs",
        "LICENSE",
        "CHANGELOG.md",
        "docs"
      ],
      links: %{
        "GitHub" => @repo_url,
        "CHANGELOG" => "#{@repo_url}/blob/main/CHANGELOG.md",
        "CodeTracer" => "https://github.com/metacraft-labs/codetracer"
      }
    ]
  end
end
