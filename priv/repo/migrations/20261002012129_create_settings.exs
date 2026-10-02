defmodule Knra.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  # System settings edited on Administration → System Settings. Only settings
  # that were changed are stored; anything missing uses its default in code.
  def change do
    create table(:settings) do
      add :key, :string, null: false
      add :value, :string, null: false
      add :updated_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:settings, [:key])

    # Set when a no-alarm pass was approved by the auto-clear setting instead of
    # the maker-checker report
    alter table(:applications) do
      add :auto_approved, :boolean, null: false, default: false
    end
  end
end
