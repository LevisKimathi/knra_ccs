defmodule Knra.Audit.Entry do
  use Ecto.Schema

  schema "audit_entries" do
    field :object_type, :string
    field :object_ref, :string
    field :actor_name, :string
    field :action, :string
    field :note, :string
    field :prev_hash, :string
    field :hash, :string
    field :inserted_at, :utc_datetime_usec

    belongs_to :actor, Knra.Accounts.User
  end
end
