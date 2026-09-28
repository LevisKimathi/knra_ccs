defmodule KnraWeb.HealthController do
  @moduledoc "Liveness check for deployments and load balancers: the app is up and the database answers."
  use KnraWeb, :controller

  def show(conn, _params) do
    Knra.Repo.query!("SELECT 1")
    text(conn, "ok")
  rescue
    _ -> conn |> put_status(503) |> text("database unavailable")
  end
end
