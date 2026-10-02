defmodule KnraWeb.PageController do
  use KnraWeb, :controller

  @doc "Sends each role to its main work screen."
  def home(conn, _params) do
    path =
      case conn.assigns.current_scope.user.role do
        "rpm_operator" -> ~p"/rpm/record"
        "cas_operator" -> ~p"/cas/lanes"
        "field_officer" -> ~p"/inspections"
        "checking_officer" -> ~p"/reports"
        "verification_officer" -> ~p"/reports"
        "supervisor" -> ~p"/cas/lanes"
        "super_admin" -> ~p"/cas/lanes"
        _ -> ~p"/applications"
      end

    redirect(conn, to: path)
  end
end
