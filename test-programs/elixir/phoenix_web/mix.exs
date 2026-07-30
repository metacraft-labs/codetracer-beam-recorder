defmodule PhoenixWeb.MixProject do
  use Mix.Project

  # RS-M8 demo app: a real Phoenix endpoint, router and controller.
  #
  # Phoenix is here for one property the plain Plug demo cannot show: the
  # router knows the *pattern* a request matched (`/api/users/:user_id`),
  # which is what `http.route` has to carry, and it turns an unmatched path
  # into a 404 through `Phoenix.Endpoint`'s error handler rather than through
  # a catch-all route.
  def project do
    [
      app: :phoenix_web,
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
      {:phoenix, "~> 1.7"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:codetracer_beam_recorder, path: "../../.."}
    ]
  end
end
