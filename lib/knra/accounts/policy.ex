defmodule Knra.Accounts.Policy do
  @moduledoc """
  Role-based access control (M1).

  Each role holds a set of permissions, edited by super admins under
  Administration → Roles (`Knra.Accounts.Roles`). This module is the catalogue
  of permissions the system understands. Every state-changing context function
  checks `authorize/2` server-side, so the UI hiding a button is never the only
  protection.
  """

  alias Knra.Accounts.{Roles, Scope, User}

  # {key, label, group, description}. Order is the order shown in the editor.
  @catalogue [
    {:view_applications, "View applications", "Screening",
     "Open screening applications and their timelines"},
    {:print_documents, "Open documents", "Screening",
     "Invoices, certificates and inspection photos"},
    {:record_rpm_pass, "Record RPM passes", "Screening",
     "The RPM operator page: look up and record passes"},
    {:view_lanes, "Lane overview and alarm queue", "Screening",
     "Live RPM lanes and alarms waiting for adjudication"},
    {:adjudicate, "Adjudicate alarms", "Screening",
     "CAS decision: release, divert to secondary, or detain"},
    {:retry_lookup, "Retry KenTrade lookups", "Screening", "Fetch consignment details again"},
    {:inspect, "Carry out secondary inspections", "Screening",
     "Record RIID readings, findings and photos"},
    {:draft_report, "Draft screening reports", "Screening", "Checking officer (maker)"},
    {:verify_report, "Verify screening reports", "Screening",
     "Verification officer (checker): approve or return"},
    {:monitor_queues, "Oversee inspection and report queues", "Screening",
     "See the queues without acting on them"},
    {:review_flagged, "Review flagged RPM passes", "Screening",
     "Passes recorded without KenTrade confirmation"},
    {:record_payment, "Record bank transfers", "Payments",
     "Confirm a bank transfer against an invoice"},
    {:reconcile_payments, "Reconcile unmatched payments", "Payments",
     "Apply M-Pesa payments with a wrong account number"},
    {:manage_devices, "Manage RPM devices", "Administration",
     "Register devices, take lanes out of service"},
    {:manage_users, "Manage users", "Administration",
     "Create, edit, suspend and reset staff accounts"},
    {:manage_fees, "Manage fee schedule", "Administration", "Propose and approve fee changes"},
    {:view_audit, "View audit trail", "Administration", "Search and export the audit trail"},
    {:view_integrations, "View integrations", "Administration", "KenTrade and status API logs"},
    {:manage_api_clients, "Manage API clients", "Administration",
     "Credentials for organisations using the status API"},
    {:receive_alert_emails, "Receive alert emails", "Notifications",
     "Detention, device-fault and similar alerts"},
    {:simulate, "Use the simulator", "Sandbox", "RPM and M-Pesa simulator (only where enabled)"}
  ]

  # Never grantable: only the Super administrator role holds it.
  @super_admin_only [:manage_roles]

  def catalogue, do: @catalogue

  def permissions, do: Enum.map(@catalogue, &elem(&1, 0)) ++ @super_admin_only

  def grantable_keys, do: Enum.map(@catalogue, &to_string(elem(&1, 0)))

  def label(key) do
    key = if is_binary(key), do: key, else: to_string(key)

    case Enum.find(@catalogue, fn {k, _, _, _} -> to_string(k) == key end) do
      {_, label, _, _} -> label
      nil -> key
    end
  end

  @doc """
  Returns true when the user in `scope` may perform `action`.

  A super admin holds every permission and is exempt from segregation of duties
  (`segregation_exempt?/1`). Only super admins may manage roles and super admin
  accounts (`manage_user?/2`).
  """
  def can?(%Scope{user: %User{status: "active", role: "super_admin"}}, action) do
    action in permissions()
  end

  def can?(%Scope{user: %User{status: "active", role: role}}, action)
      when action not in @super_admin_only do
    to_string(action) in Roles.permissions(role)
  end

  def can?(_scope, _action), do: false

  @doc """
  Super admins may act as both maker and checker: verify a report they drafted
  and approve their own fee proposal. Such actions are flagged in the audit trail.
  """
  def segregation_exempt?(%Scope{user: %User{status: "active", role: "super_admin"}}), do: true
  def segregation_exempt?(_), do: false

  @doc "May `scope` create, edit, suspend or reset `target` (or give it `new_role`)?"
  def manage_user?(scope, %User{role: target_role}, new_role \\ nil) do
    can?(scope, :manage_users) and
      (scope.user.role == "super_admin" or
         "super_admin" not in [target_role, new_role])
  end

  def authorize(scope, action) do
    if can?(scope, action), do: :ok, else: {:error, :unauthorized}
  end
end
