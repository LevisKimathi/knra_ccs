defmodule Knra.Repo.Migrations.ApiClientsTokenLookup do
  use Ecto.Migration

  # Clients are identified by their token alone (no From header), so the stored
  # token hash and the username must each be unique.
  def change do
    create unique_index(:api_clients, [:token_hash])
    create unique_index(:api_clients, [:username])

    alter table(:api_clients) do
      add :last_used_ip, :string
    end
  end
end
