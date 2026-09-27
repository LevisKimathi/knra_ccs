defmodule Knra.Repo.Migrations.CreateAuditLog do
  use Ecto.Migration

  def change do
    create table(:audit_entries) do
      add :object_type, :string, null: false
      add :object_ref, :string, null: false
      add :actor_id, references(:users, on_delete: :nothing)
      add :actor_name, :string, null: false
      add :action, :string, null: false
      add :note, :text
      add :prev_hash, :string, null: false
      add :hash, :string, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:audit_entries, [:object_type, :object_ref])
    create index(:audit_entries, [:actor_id])
    create index(:audit_entries, [:inserted_at])
    create unique_index(:audit_entries, [:hash])

    # The audit log is append-only: reject every UPDATE and DELETE at the database level.
    execute(
      """
      CREATE FUNCTION audit_entries_append_only() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'audit_entries is append-only';
      END;
      $$ LANGUAGE plpgsql;
      """,
      "DROP FUNCTION audit_entries_append_only()"
    )

    execute(
      """
      CREATE TRIGGER audit_entries_no_update_delete
      BEFORE UPDATE OR DELETE ON audit_entries
      FOR EACH ROW EXECUTE FUNCTION audit_entries_append_only();
      """,
      "DROP TRIGGER audit_entries_no_update_delete ON audit_entries"
    )
  end
end
