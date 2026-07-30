defmodule PhoenixWeb.ErrorHTML do
  @moduledoc "Phoenix's `render_errors` view for HTML."

  def render(template, _assigns), do: "error: " <> template
end
