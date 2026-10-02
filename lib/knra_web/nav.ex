defmodule KnraWeb.Nav do
  @moduledoc """
  The left menu and each user's landing page, derived from permissions (not role
  names), so a role edited under Administration → Roles gets the matching screens.
  """
  use KnraWeb, :verified_routes

  alias Knra.Accounts.Policy

  @doc "Where a user lands after login: their main work screen."
  def home_path(scope) do
    can = &Policy.can?(scope, &1)

    cond do
      can.(:view_lanes) -> ~p"/cas/lanes"
      can.(:record_rpm_pass) -> ~p"/rpm/record"
      can.(:inspect) -> ~p"/inspections"
      can.(:draft_report) or can.(:verify_report) -> ~p"/reports"
      can.(:monitor_queues) -> ~p"/reports"
      can.(:view_applications) -> ~p"/applications"
      can.(:manage_users) -> ~p"/admin/users"
      true -> ~p"/users/settings"
    end
  end

  @doc "Menu sections as `[{title, [%{key, label, path}]}]`."
  def sections(nil), do: []

  def sections(scope) do
    can = &Policy.can?(scope, &1)

    work =
      [
        can.(:record_rpm_pass) && item("rpm_pass", "Record RPM Pass", ~p"/rpm/record"),
        can.(:view_lanes) && item("lanes", "Lane Overview", ~p"/cas/lanes"),
        can.(:view_lanes) && item("alarms", "Alarm Queue", ~p"/cas/alarms"),
        (can.(:inspect) or can.(:monitor_queues)) &&
          item(
            "inspections",
            if(can.(:inspect) and not can.(:monitor_queues),
              do: "My Inspections",
              else: "Secondary Inspections"
            ),
            ~p"/inspections"
          ),
        (can.(:draft_report) or can.(:verify_report) or can.(:monitor_queues)) &&
          item("reports", "Screening Reports", ~p"/reports"),
        can.(:review_flagged) && item("flagged", "Flagged Passes", ~p"/reviews"),
        can.(:view_applications) && item("applications", "All Applications", ~p"/applications")
      ]

    admin = [
      can.(:manage_devices) && item("devices", "RPM Devices", ~p"/admin/devices"),
      can.(:manage_users) && item("users", "Users", ~p"/admin/users"),
      can.(:manage_roles) && item("roles", "Roles & Permissions", ~p"/admin/roles"),
      can.(:manage_settings) && item("settings", "System Settings", ~p"/admin/settings"),
      can.(:manage_fees) && item("fees", "Fee Schedule", ~p"/admin/fees"),
      can.(:reconcile_payments) && item("payments", "Payments", ~p"/admin/payments"),
      can.(:view_audit) && item("audit", "Audit Trail", ~p"/admin/audit"),
      can.(:view_integrations) && item("integrations", "Integrations", ~p"/admin/integrations"),
      can.(:manage_api_clients) && item("api_clients", "API Clients", ~p"/admin/api-clients")
    ]

    tools =
      [
        (Knra.Simulator.enabled?() and can.(:simulate)) &&
          item("simulator", "RPM & M-Pesa Simulator", ~p"/simulator")
      ]

    [{"Screens", work}, {"Administration", admin}, {"Sandbox", tools}]
    |> Enum.map(fn {title, items} -> {title, Enum.filter(items, & &1)} end)
  end

  @doc "The work queue an application page links back to, and which menu item is active."
  def back_for_application(scope) do
    can = &Policy.can?(scope, &1)

    cond do
      can.(:adjudicate) -> {~p"/cas/alarms", "applications"}
      can.(:inspect) -> {~p"/inspections", "inspections"}
      can.(:draft_report) or can.(:verify_report) -> {~p"/reports", "reports"}
      can.(:record_rpm_pass) -> {~p"/rpm/record", "applications"}
      true -> {~p"/applications", "applications"}
    end
  end

  defp item(key, label, path), do: %{key: key, label: label, path: path}
end
