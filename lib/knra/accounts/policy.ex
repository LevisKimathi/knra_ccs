defmodule Knra.Accounts.Policy do
  @moduledoc """
  Role-based access control (M1).

  Every state-changing context function checks `authorize/2` server-side, so the UI
  hiding a button is never the only protection.
  """

  alias Knra.Accounts.{Scope, User}

  @permissions %{
    view_applications: ~w(cas_operator field_officer checking_officer verification_officer supervisor),
    print_documents: ~w(cas_operator field_officer checking_officer verification_officer supervisor),
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

  @doc "Returns true when the user in `scope` may perform `action`."
  def can?(%Scope{user: %User{status: "active", role: role}}, action) do
    role in Map.get(@permissions, action, [])
  end

  def can?(_scope, _action), do: false

  def authorize(scope, action) do
    if can?(scope, action), do: :ok, else: {:error, :unauthorized}
  end
end
