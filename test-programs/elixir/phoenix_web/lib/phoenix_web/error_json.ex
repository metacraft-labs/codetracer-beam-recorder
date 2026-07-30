defmodule PhoenixWeb.ErrorJSON do
  @moduledoc "Phoenix's `render_errors` view for JSON."

  def render(template, _assigns), do: %{error: template}
end
