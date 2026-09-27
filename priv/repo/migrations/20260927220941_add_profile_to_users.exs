defmodule Knra.Repo.Migrations.AddProfileToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :name, :string, null: false, default: ""
      add :staff_number, :string
      add :role, :string, null: false, default: "cas_operator"
      add :station, :string
      add :status, :string, null: false, default: "active"
      add :last_active_at, :utc_datetime
    end

    create index(:users, [:role])
    create unique_index(:users, [:staff_number])
  end
end
