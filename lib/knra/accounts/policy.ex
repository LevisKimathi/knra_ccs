defmodule Knra.Accounts.Policy do
  @moduledoc """
  Role-based access control (M1).

  Every state-changing context function checks `authorize/2` server-side, so the UI
  hiding a button is never the only protection.
  """

  alias Knra.Accounts.{Scope, User}

  @permissions %{
    view_applications:
      ~w(cas_operator field_officer checking_officer verification_officer supervisor),
    print_documents:
      ~w(cas_operator field_officer checking_officer verification_officer supervisor),
    adjudicate: ~w(cas_operator),
    retry_lookup: ~w(cas_operator supervisor),
    record_payment: ~w(cas_operator supervisor),
    reconcile_payments: ~w(supervisor),
    inspect: ~w(field_officer),
    draft_report: ~w(checking_officer),
    verify_report: ~w(verification_officer),
    view_lanes: ~w(cas_operator supervisor),
    manage_devices: ~w(supervisor),
    manage_users: ~w(supervisor),
    manage_fees: ~w(supervisor),
    view_audit: ~w(supervisor),
    view_integrations: ~w(supervisor),
    simulate: ~w(cas_operator supervisor)
  }

  def permissions, do: Map.keys(@permissions)

  @doc """
  Returns true when the user in `scope` may perform `action`.

  A super admin holds every permission. Per-record rules still apply on top of
  this (a report's drafter cannot verify it; a fee proposal needs a different
  approver), and only super admins may manage super admin accounts
  (`manage_user?/2`).
  """
  def can?(%Scope{user: %User{status: "active", role: "super_admin"}}, action) do
    action in Map.keys(@permissions)
  end

  def can?(%Scope{user: %User{status: "active", role: role}}, action) do
    role in Map.get(@permissions, action, [])
  end

  def can?(_scope, _action), do: false

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
