defmodule Knra.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  # Roles and their permissions move from code into the database so super admins
  # can edit them. The built-in roles are created with exactly the permissions
  # they had in code, so nobody's access changes on deploy. Super administrator
  # holds every permission implicitly and is not editable.
  @built_in [
    {"rpm_operator", "RPM operator", "Records RPM passes at the berth",
     ~w(view_applications record_rpm_pass)},
    {"cas_operator", "CAS operator", "Central Alarm Station: lanes, alarms and adjudication",
     ~w(view_applications print_documents adjudicate retry_lookup record_payment view_lanes simulate)},
    {"field_officer", "Field inspection officer", "Secondary inspections at the divert bay",
     ~w(view_applications print_documents inspect)},
    {"checking_officer", "Checking officer", "Drafts screening reports (maker)",
     ~w(view_applications print_documents draft_report)},
    {"verification_officer", "Verification officer", "Verifies screening reports (checker)",
     ~w(view_applications print_documents verify_report)},
    {"supervisor", "Supervisor / administrator", "Oversight and administration",
     ~w(view_applications print_documents retry_lookup record_payment reconcile_payments view_lanes
        monitor_queues review_flagged manage_devices manage_users manage_fees view_audit
        view_integrations manage_api_clients receive_alert_emails simulate)},
    {"super_admin", "Super administrator", "Every permission; manages roles and super admins", []}
  ]

  def up do
    create table(:roles) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :description, :string
      add :permissions, {:array, :string}, null: false, default: []
      add :built_in, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:roles, [:key])
    create unique_index(:roles, [:name])

    flush()

    now = DateTime.utc_now(:second)

    repo().insert_all(
      "roles",
      for {key, name, desc, perms} <- @built_in do
        %{
          key: key,
          name: name,
          description: desc,
          permissions: perms,
          built_in: true,
          inserted_at: now,
          updated_at: now
        }
      end
    )
  end

  def down do
    drop table(:roles)
  end
end
