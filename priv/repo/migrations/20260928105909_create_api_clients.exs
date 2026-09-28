defmodule Knra.Repo.Migrations.CreateApiClients do
  use Ecto.Migration

  # Organisations allowed to call the container status API. Each sends its
  # client code in `From` and sha256_hex("username:password") as the Basic token.
  # Only a SHA-256 of that token is stored, so a database leak does not reveal a
  # usable credential.
  def change do
    create table(:api_clients) do
      add :name, :string, null: false
      add :client_code, :string, null: false
      add :username, :string, null: false
      add :token_hash, :string, null: false
      add :status, :string, null: false, default: "active"
      add :last_used_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_clients, [:client_code])
  end
end
