defmodule PhoenixWeb.UserController do
  @moduledoc "Handlers for the RS-M8 Phoenix demo."

  use Phoenix.Controller, formats: []

  @users %{"1" => "ada", "2" => "grace", "3" => "barbara"}

  def healthz(conn, _params), do: text(conn, "ok")

  def index(conn, _params) do
    text(conn, @users |> Map.values() |> Enum.sort() |> Enum.join(","))
  end

  def create(conn, _params) do
    conn |> Plug.Conn.put_status(201) |> text("created")
  end

  def show(conn, %{"user_id" => user_id}) do
    case Map.fetch(@users, user_id) do
      {:ok, name} -> text(conn, name)
      :error -> conn |> Plug.Conn.put_status(404) |> text("no such user")
    end
  end

  def boom(_conn, _params), do: raise("phoenix demo handler failure")
end
