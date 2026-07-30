defmodule PhoenixWeb.ReportController do
  @moduledoc "A two-segment parameterised route, so `http.route` has something to collapse."

  use Phoenix.Controller, formats: []

  def show(conn, %{"report_id" => report_id, "row_id" => row_id}) do
    text(conn, "report #{report_id} row #{row_id}")
  end
end
