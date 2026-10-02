defmodule Knra.Settings.Setting do
  use Ecto.Schema

  schema "settings" do
    field :key, :string
    field :value, :string
    belongs_to :updated_by, Knra.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
