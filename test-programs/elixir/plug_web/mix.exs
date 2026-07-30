defmodule PlugWeb.MixProject do
  use Mix.Project

  # RS-M8 demo app: a real Plug router served by a real Cowboy listener.
  #
  # This is `test-programs/elixir/plug_smoke` promoted to the genuine article.
  # `plug_smoke` hand-rolls HTTP over `:gen_tcp` so it can run with no
  # dependencies at all; this program is here to prove the recorder's Plug
  # middleware against the framework people actually deploy, so it takes
  # `plug_cowboy` from Hex and the recorder itself as a path dependency.
  def project do
    [
      app: :plug_web,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :inets]]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:codetracer_beam_recorder, path: "../../.."}
    ]
  end
end
