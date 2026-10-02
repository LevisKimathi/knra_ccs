defmodule KnraWeb.PageController do
  use KnraWeb, :controller

  @doc "Sends each user to their main work screen, based on their role's permissions."
  def home(conn, _params) do
    path = KnraWeb.Nav.home_path(conn.assigns.current_scope)

    redirect(conn, to: path)
  end
end
