defmodule Knra.Accounts.Role do
  use Ecto.Schema
  import Ecto.Changeset

  alias Knra.Accounts.Policy

  schema "roles" do
    field :key, :string
    field :name, :string
    field :description, :string
    field :permissions, {:array, :string}, default: []
    field :built_in, :boolean, default: false
    field :user_count, :integer, virtual: true, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description, :permissions])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 200)
    |> update_change(
      :permissions,
      &(&1 |> Enum.reject(fn p -> p in [nil, ""] end) |> Enum.uniq() |> Enum.sort())
    )
    |> validate_subset(:permissions, Policy.grantable_keys(),
      message: "contains an unknown permission"
    )
    |> validate_change(:permissions, fn :permissions, perms ->
      if "draft_report" in perms and "verify_report" in perms,
        do: [
          permissions:
            "cannot include both Draft screening reports and Verify screening reports (maker–checker)"
        ],
        else: []
    end)
    |> unique_constraint(:name, message: "is already used by another role")
    |> unique_constraint(:key)
  end

  def super_admin?(%__MODULE__{key: "super_admin"}), do: true
  def super_admin?(_), do: false
end
