defmodule KnraWeb.Admin.RolesLive do
  @moduledoc """
  Roles & Permissions (super admins only). Edit what each role may do, add new
  roles, and delete unused custom roles. Changes apply on users' next page load
  and are recorded in the audit trail.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :manage_roles}}

  alias Knra.Accounts.{Policy, Role, Roles}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav_counts={@nav_counts} active="roles">
      <.page_header title="Roles & Permissions">
        <:subtitle>
          What each role may see and do. Changes apply on users' next page load and are recorded in
          the audit trail. A role cannot both draft and verify screening reports.
        </:subtitle>
        <:actions>
          <.link :if={@live_action == :index} patch={~p"/admin/roles/new"} class={btn(:primary, :sm)}>
            Add Role
          </.link>
        </:actions>
      </.page_header>

      <.card
        :if={@live_action in [:new, :edit]}
        title={if @live_action == :new, do: "Add Role", else: "Edit #{@role.name}"}
        class="mb-6"
        id="role-editor"
      >
        <.form for={@form} id="role-form" phx-change="validate" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2">
            <.input field={@form[:name]} label="Role name" placeholder="e.g. Shift supervisor" />
            <.input
              field={@form[:description]}
              label="Description"
              placeholder="What this role is for"
            />
          </div>

          <input type="hidden" name="role[permissions][]" value="" />
          <div class="mb-4 grid gap-5 lg:grid-cols-2">
            <fieldset :for={{group, perms} <- groups()} class="rounded border border-line">
              <legend class="ml-3 px-1 text-[11px] font-bold uppercase tracking-[0.06em] text-muted">
                {group}
              </legend>
              <label
                :for={{key, label, _group, desc} <- perms}
                class="flex cursor-pointer items-start gap-3 border-b border-line-soft px-4 py-2.5 last:border-0 hover:bg-panel"
              >
                <input
                  type="checkbox"
                  name="role[permissions][]"
                  value={key}
                  id={"perm-#{key}"}
                  checked={to_string(key) in selected(@form)}
                  class="mt-0.5 size-4 accent-brand"
                />
                <span>
                  <span class="block text-sm font-semibold">{label}</span>
                  <span class="block text-xs text-muted">{desc}</span>
                </span>
              </label>
            </fieldset>
          </div>
          <p :for={msg <- errors_for(@form, :permissions)} class="mb-3 text-sm text-error">{msg}</p>

          <div class="flex flex-wrap gap-2">
            <button type="submit" class={btn(:primary, :sm)} phx-disable-with="Saving…">
              {if @live_action == :new, do: "Create Role", else: "Save Changes"}
            </button>
            <.link patch={~p"/admin/roles"} class={btn(:secondary, :sm)}>Cancel</.link>
          </div>
        </.form>
      </.card>

      <div class="grid gap-4 md:grid-cols-2">
        <div
          :for={r <- @roles}
          id={"role-#{r.key}"}
          class="flex flex-col rounded-md border border-line bg-white p-5"
        >
          <div class="mb-1 flex items-start gap-2">
            <h2 class="flex-1 text-[15px] font-bold">{r.name}</h2>
            <.pill :if={Role.super_admin?(r)} tone={:info}>All permissions</.pill>
            <.pill :if={r.built_in and not Role.super_admin?(r)} tone={:neutral}>Built-in</.pill>
            <.pill :if={not r.built_in} tone={:ok}>Custom</.pill>
          </div>
          <p :if={r.description} class="mb-3 text-[13px] text-muted">{r.description}</p>
          <div class="mb-3 text-xs text-subtle">
            {r.user_count} {if r.user_count == 1, do: "user", else: "users"}
            <span :if={not Role.super_admin?(r)}>
              · {length(r.permissions)} {if length(r.permissions) == 1,
                do: "permission",
                else: "permissions"}
            </span>
          </div>
          <div :if={not Role.super_admin?(r)} class="mb-4 flex flex-wrap gap-1.5">
            <span
              :for={p <- r.permissions}
              class="rounded bg-canvas px-2 py-0.5 text-xs text-muted"
            >
              {Policy.label(p)}
            </span>
            <span :if={r.permissions == []} class="text-xs text-subtle">No permissions</span>
          </div>
          <p :if={Role.super_admin?(r)} class="mb-4 text-xs text-muted">
            Holds every permission, manages roles and super admin accounts, and is exempt from
            segregation of duties. It cannot be edited.
          </p>
          <div :if={not Role.super_admin?(r)} class="mt-auto flex flex-wrap gap-2">
            <.link patch={~p"/admin/roles/#{r.id}/edit"} class={btn(:secondary, :sm)}>
              Edit Permissions
            </.link>
            <button
              :if={not r.built_in}
              phx-click="delete"
              phx-value-id={r.id}
              data-confirm={"Delete the #{r.name} role? This cannot be undone."}
              data-confirm-title="Delete Role"
              data-confirm-button="Delete"
              data-confirm-variant="danger"
              class={btn(:danger, :sm)}
            >
              Delete
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(:page_title, "Roles & Permissions") |> load()}

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :new, _),
    do: assign(socket, role: %Role{}, form: to_form(Roles.change_role(%Role{})))

  defp apply_action(socket, :edit, %{"id" => id}) do
    role = Roles.get_role!(id)

    if Role.super_admin?(role) do
      socket
      |> put_flash(:error, Roles.error_message(:super_admin_role))
      |> push_patch(to: ~p"/admin/roles")
    else
      assign(socket, role: role, form: to_form(Roles.change_role(role)))
    end
  end

  defp apply_action(socket, :index, _), do: assign(socket, role: nil, form: nil)

  @impl true
  def handle_event("validate", %{"role" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Roles.change_role(socket.assigns.role, params), action: :validate)
     )}
  end

  def handle_event("save", %{"role" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.live_action do
        :new -> Roles.create_role(scope, params)
        :edit -> Roles.update_role(scope, socket.assigns.role, params)
      end

    case result do
      {:ok, role} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{role.name} saved.")
         |> push_patch(to: ~p"/admin/roles")
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Roles.error_message(reason))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Roles.delete_role(socket.assigns.current_scope, Roles.get_role!(id)) do
      {:ok, role} -> {:noreply, socket |> put_flash(:info, "#{role.name} deleted.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Roles.error_message(reason))}
    end
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket), do: assign(socket, :roles, Roles.list_roles())

  defp groups do
    Policy.catalogue()
    |> Enum.group_by(&elem(&1, 2))
    |> Enum.sort_by(fn {g, _} ->
      Enum.find_index(
        ~w(Screening Payments Reporting Administration Notifications Sandbox),
        &(&1 == g)
      )
    end)
  end

  defp selected(form) do
    case form[:permissions].value do
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp errors_for(form, field) do
    form.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {msg, _} -> msg end)
  end
end
