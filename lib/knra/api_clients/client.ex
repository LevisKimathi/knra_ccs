defmodule Knra.ApiClients.Client do
  use Ecto.Schema
  import Ecto.Changeset

  schema "api_clients" do
    field :name, :string
    field :client_code, :string
    field :username, :string
    field :token_hash, :string, redact: true
    field :status, :string, default: "active"
    field :last_used_at, :utc_datetime

    belongs_to :created_by, Knra.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [:name, :client_code, :username])
    |> update_change(:client_code, &(&1 |> String.trim() |> String.upcase()))
    |> update_change(:username, &String.trim/1)
    |> validate_required([:name, :client_code, :username])
    |> validate_length(:name, max: 120)
    |> validate_format(:client_code, ~r/^[A-Z0-9_\-]{2,40}$/,
      message: "use 2-40 letters, digits, - or _"
    )
    |> validate_format(:username, ~r/^[^:\s]{2,60}$/,
      message: "2-60 characters, no spaces or colons"
    )
    |> unique_constraint(:client_code, message: "is already used by another client")
  end

  def active?(%__MODULE__{status: "active"}), do: true
  def active?(_), do: false
end
