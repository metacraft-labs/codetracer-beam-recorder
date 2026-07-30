defmodule PhoenixWeb.Router do
  @moduledoc """
  Routes for the RS-M8 Phoenix demo.

  The parameterised routes are the point: `/api/users/7` must be recorded with
  `http.route == "/api/users/:user_id"`, not with the path the client typed.
  """

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json", "html"])
  end

  scope "/api", PhoenixWeb do
    pipe_through(:api)

    get("/users", UserController, :index)
    post("/users", UserController, :create)
    get("/users/:user_id", UserController, :show)
    get("/reports/:report_id/rows/:row_id", ReportController, :show)
    get("/boom", UserController, :boom)
  end

  scope "/", PhoenixWeb do
    get("/healthz", UserController, :healthz)
  end
end
