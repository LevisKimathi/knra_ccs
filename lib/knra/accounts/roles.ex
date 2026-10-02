defmodule Knra.Accounts.Roles do
  @moduledoc """
  Roles and their permissions, stored in the database and edited by super
  admins (Administration → Roles).

  Permission checks read an in-memory copy (`:persistent_term`) that is reloaded
  whenever a role changes, and on other nodes via PubSub. With
  `config :knra, :role_cache, false` (tests) every lookup reads the database.

  Super administrator is built in: it holds every permission implicitly and
  cannot be edited or deleted. Built-in roles can be edited but not deleted;
  custom roles can be deleted once no user holds them.
  """

  import Ecto.Query

  alias Knra.{Audit, Repo}
  alias Knra.Accounts.{Policy, Role, User}

  @cache_key {__MODULE__, :roles}
  @topic "roles"

  ## Lookups (used by every permission check)

  @doc "Permission keys (strings) granted to the role with this key."
  def permissions(key) do
    case Map.get(all_by_key(), key) do
      %Role{permissions: perms} -> perms
      nil -> []
    end
  end

  def label(key) do
    case Map.get(all_by_key(), key) do
      %Role{name: name} -> name
      nil -> key
    end
  end

  def exists?(key), do: Map.has_key?(all_by_key(), key)

  @doc "Role keys whose permissions include `permission` (super admin always included)."
  def keys_with_permission(permission) do
    p = to_string(permission)

    all_by_key()
    |> Enum.filter(fn {key, r} -> key == "super_admin" or p in r.permissions end)
    |> Enum.map(fn {key, _} -> key end)
  end

  @doc "`{name, key}` options for a role select."
  def options(opts \\ []) do
    exclude = Keyword.get(opts, :exclude, [])

    all_by_key()
    |> Map.values()
    |> Enum.reject(&(&1.key in exclude))
    |> Enum.sort_by(&{&1.key == "super_admin", &1.id})
    |> Enum.map(&{&1.name, &1.key})
  end

  defp all_by_key do
    if Application.get_env(:knra, :role_cache, true) do
      case :persistent_term.get(@cache_key, nil) do
        nil -> reload()
        roles -> roles
      end
    else
      load()
    end
  end

  defp load, do: Repo.all(Role) |> Map.new(&{&1.key, &1})

  @doc "Reloads the in-memory copy of the roles."
  def reload do
    roles = load()
    if Application.get_env(:knra, :role_cache, true), do: :persistent_term.put(@cache_key, roles)
    roles
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Knra.PubSub, @topic)

  defp changed do
    reload()
    Phoenix.PubSub.broadcast(Knra.PubSub, @topic, :roles_changed)
  end

  ## Administration (super admins only)

  def list_roles do
    counts =
      Repo.all(
        from u in User,
          where: u.status != "deactivated",
          group_by: u.role,
          select: {u.role, count(u.id)}
      )
      |> Map.new()

    Repo.all(from r in Role, order_by: [desc: r.built_in, asc: r.id])
    |> Enum.map(&%{&1 | user_count: Map.get(counts, &1.key, 0)})
  end

  def get_role!(id), do: Repo.get!(Role, id)
  def change_role(%Role{} = role, attrs \\ %{}), do: Role.changeset(role, attrs)

  def create_role(scope, attrs) do
    with :ok <- Policy.authorize(scope, :manage_roles) do
      cs = Role.changeset(%Role{built_in: false}, attrs)
      cs = Ecto.Changeset.put_change(cs, :key, unique_key(Ecto.Changeset.get_field(cs, :name)))

      Repo.transaction(fn ->
        case Repo.insert(cs) do
          {:ok, role} ->
            Audit.log(
              scope,
              :role,
              role.key,
              "Role created — #{role.name}",
              perms_note(role.permissions)
            )

            role

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
      |> tap_changed()
    end
  end

  def update_role(scope, %Role{} = role, attrs) do
    with :ok <- Policy.authorize(scope, :manage_roles),
         :ok <- editable(role) do
      Repo.transaction(fn ->
        case Repo.update(Role.changeset(role, attrs)) do
          {:ok, updated} ->
            added = updated.permissions -- role.permissions
            removed = role.permissions -- updated.permissions

            note =
              [
                role.name != updated.name && "renamed from #{role.name}",
                added != [] && "added: #{Enum.map_join(added, ", ", &Policy.label/1)}",
                removed != [] && "removed: #{Enum.map_join(removed, ", ", &Policy.label/1)}"
              ]
              |> Enum.filter(& &1)
              |> Enum.join("; ")

            Audit.log(scope, :role, updated.key, "Role updated — #{updated.name}", note)
            updated

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
      |> tap_changed()
    end
  end

  def delete_role(scope, %Role{} = role) do
    in_use = Repo.exists?(from u in User, where: u.role == ^role.key)

    cond do
      Policy.authorize(scope, :manage_roles) != :ok ->
        {:error, :unauthorized}

      role.built_in ->
        {:error, :built_in_role}

      in_use ->
        {:error, :role_in_use}

      true ->
        Repo.transaction(fn ->
          Repo.delete!(role)
          Audit.log(scope, :role, role.key, "Role deleted — #{role.name}")
          role
        end)
        |> tap_changed()
    end
  end

  defp editable(%Role{key: "super_admin"}), do: {:error, :super_admin_role}
  defp editable(_), do: :ok

  defp tap_changed({:ok, _} = result) do
    changed()
    result
  end

  defp tap_changed(other), do: other

  defp perms_note([]), do: "no permissions"
  defp perms_note(perms), do: Enum.map_join(perms, ", ", &Policy.label/1)

  defp unique_key(nil), do: nil

  defp unique_key(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 40)
      |> then(&if(&1 == "", do: "role", else: &1))

    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 ->
        unless Repo.exists?(from r in Role, where: r.key == ^base), do: base

      n ->
        unless Repo.exists?(from r in Role, where: r.key == ^"#{base}_#{n}"), do: "#{base}_#{n}"
    end)
  end

  def error_message(:built_in_role), do: "Built-in roles cannot be deleted."
  def error_message(:role_in_use), do: "Move the users who hold this role to another role first."

  def error_message(:super_admin_role),
    do: "The Super administrator role always has every permission and cannot be edited."

  def error_message(:unauthorized), do: "Only super admins can manage roles."
  def error_message(other), do: "Action failed: #{inspect(other)}"
end
