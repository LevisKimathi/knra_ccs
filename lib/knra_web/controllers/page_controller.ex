defmodule KnraWeb.PageController do
  use KnraWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
