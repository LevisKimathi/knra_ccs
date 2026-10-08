defmodule Knra.Repo.Migrations.GrantViewReports do
  use Ecto.Migration

  # New permission "View reports" (Reporting section); supervisors get it by default.
  def up do
    execute """
    UPDATE roles SET permissions = array_append(permissions, 'view_reports')
    WHERE key = 'supervisor' AND NOT ('view_reports' = ANY(permissions))
    """
  end

  def down do
    execute "UPDATE roles SET permissions = array_remove(permissions, 'view_reports')"
  end
end
