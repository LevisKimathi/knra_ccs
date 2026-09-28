defmodule KnraWeb.Admin.UsersLive do
  @moduledoc """
  Staff accounts and roles (M1). Each user holds exactly one role. New users get
  an emailed link to confirm their account; they then set a password.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :manage_users}}

  alias Knra.Accounts
  alias Knra.Accounts.{Policy, User}

  @cols "1fr 190px 190px 130px 110px 230px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav_counts={@nav_counts} active="users">
      <.page_header title="Users & roles">
        <:subtitle>
          Roles mirror the KNRA Single Window model. Each user holds one role at a time, so the checking
          and verification officer on a report are always different people. Suspending a user ends their sessions immediately.
        </:subtitle>
        <:actions>
          <.link patch={~p"/admin/users/new"} class={btn(:primary, :sm)}>Add user</.link>
        </:actions>
      </.page_header>

      <.card
        :if={@live_action in [:new, :edit]}
        title={if @live_action == :new, do: "Add user", else: "Edit #{@user.name}"}
        class="mb-5"
      >
        <.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-2 lg:grid-cols-3">
            <.input field={@form[:name]} label="Full name" />
            <.input field={@form[:email]} type="email" label="Email" />
            <.input field={@form[:staff_number]} label="Staff number" />
            <.input
              field={@form[:role]}
              type="select"
              label="Role"
              options={User.assignable_role_options(@current_scope.user)}
            />
            <.input
              field={@form[:station]}
              label="Duty station"
              placeholder="e.g. CAS, KOT Terminal 1"
            />
          </div>
          <p :if={@live_action == :new} class="mb-3 text-xs text-muted">
            The user will receive an email link to confirm the account and log in.
          </p>
          <p :if={@live_action == :edit} class="mb-3 text-xs text-muted">
            Changing the role or email ends the user's current sessions.
          </p>
          <div class="flex gap-2">
            <button type="submit" class={btn(:primary, :sm)} phx-disable-with="Saving…">
              Save
            </button>
            <.link patch={~p"/admin/users"} class={btn(:secondary, :sm)}>Cancel</.link>
          </div>
        </.form>
      </.card>

      <.form for={@filter} id="user-filter" phx-change="filter" class="mb-4 flex flex-wrap gap-3">
        <div class="min-w-64 flex-1">
          <.input field={@filter[:q]} placeholder="Search name or email" phx-debounce="300" />
        </div>
        <div class="w-64">
          <.input
            field={@filter[:role]}
            type="select"
            prompt="All roles"
            options={User.role_options()}
          />
        </div>
      </.form>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Name</div>
          <div>Role</div>
          <div>Station</div>
          <div>Last active</div>
          <div>Status</div>
          <div></div>
        </.thead>
        <div
          :for={u <- @users}
          id={"user-#{u.id}"}
          class="grid items-center gap-1 border-b border-line-soft px-5 py-3 text-[13px] last:border-0 md:gap-3"
          style={"--cols: #{@cols}"}
        >
          <div>
            <div class="font-semibold">{u.name}</div>
            <div class="text-xs text-muted">{u.email}{u.staff_number && " · #{u.staff_number}"}</div>
          </div>
          <div>{User.role_label(u.role)}</div>
          <div class="text-muted">{u.station}</div>
          <div class="text-xs text-muted">{Knra.Time.format(u.last_active_at)}</div>
          <div>
            <.pill tone={status_tone(u.status)}>{String.capitalize(u.status)}</.pill>
            <div :if={is_nil(u.confirmed_at)} class="mt-1 text-xs text-subtle">Invite pending</div>
          </div>
          <div
            :if={u.id != @current_scope.user.id and Policy.manage_user?(@current_scope, u)}
            class="flex flex-wrap justify-end gap-1.5"
          >
            <.link patch={~p"/admin/users/#{u.id}/edit"} class={btn(:secondary, :sm)}>Edit</.link>
            <button
              :if={u.status == "active"}
              phx-click="status"
              phx-value-id={u.id}
              phx-value-status="suspended"
              data-confirm={"Suspend #{u.name}? Their sessions end immediately."}
              class={btn(:warn, :sm)}
            >
              Suspend
            </button>
            <button
              :if={u.status != "active"}
              phx-click="status"
              phx-value-id={u.id}
              phx-value-status="active"
              class={btn(:ok, :sm)}
            >
              Reactivate
            </button>
            <button
              :if={u.status == "suspended"}
              phx-click="status"
              phx-value-id={u.id}
              phx-value-status="deactivated"
              data-confirm={"Deactivate #{u.name}? Use this when they leave KNRA."}
              class={btn(:danger, :sm)}
            >
              Deactivate
            </button>
            <button
              :if={u.status == "active"}
              phx-click="reset"
              phx-value-id={u.id}
              data-confirm={"Clear #{u.name}'s password and email them a login link?"}
              class={btn(:secondary, :sm)}
            >
              Reset password
            </button>
          </div>
          <div :if={u.id == @current_scope.user.id} class="text-right text-xs text-subtle">You</div>
          <div
            :if={u.id != @current_scope.user.id and not Policy.manage_user?(@current_scope, u)}
            class="text-right text-xs text-subtle"
          >
            Managed by super admins
          </div>
        </div>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Users & roles", filters: %{}) |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    user = %User{role: "cas_operator"}
    assign(socket, user: user, form: to_form(Accounts.change_user_admin(user)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = Accounts.get_user!(id)

    if Policy.manage_user?(socket.assigns.current_scope, user) do
      assign(socket, user: user, form: to_form(Accounts.change_user_admin(user)))
    else
      socket
      |> put_flash(:error, "Only a super admin can edit this account.")
      |> push_patch(to: ~p"/admin/users")
    end
  end

  defp apply_action(socket, :index, _params), do: assign(socket, user: nil, form: nil)

  @impl true
  def handle_event("filter", %{"filter" => f}, socket),
    do: {:noreply, socket |> assign(:filters, f) |> load()}

  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Accounts.change_user_admin(socket.assigns.user, params), action: :validate)
     )}
  end

  def handle_event("save", %{"user" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.live_action do
        :new -> Accounts.create_user(scope, params, &url(~p"/users/log-in/#{&1}"))
        :edit -> Accounts.update_user(scope, socket.assigns.user, params)
      end

    case result do
      {:ok, {_user, tokens}} ->
        KnraWeb.UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket |> put_flash(:info, "User updated.") |> push_patch(to: ~p"/admin/users") |> load()}

      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{user.name} added. A login link was emailed to #{user.email}.")
         |> push_patch(to: ~p"/admin/users")
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  def handle_event("status", %{"id" => id, "status" => status}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.set_user_status(socket.assigns.current_scope, user, status) do
      {:ok, {u, tokens}} ->
        KnraWeb.UserAuth.disconnect_sessions(tokens)
        {:noreply, socket |> put_flash(:info, "#{u.name} is now #{u.status}.") |> load()}

      {:error, :cannot_change_self} ->
        {:noreply, put_flash(socket, :error, "You cannot change your own account status.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  def handle_event("reset", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.force_password_reset(
           socket.assigns.current_scope,
           user,
           &url(~p"/users/log-in/#{&1}")
         ) do
      {:ok, {u, tokens}} ->
        KnraWeb.UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> put_flash(:info, "Password cleared. A login link was emailed to #{u.email}.")
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  defp load(socket) do
    socket
    |> assign(:users, Accounts.list_users(socket.assigns.filters))
    |> assign(:filter, to_form(socket.assigns.filters, as: :filter))
  end

  defp status_tone("active"), do: :ok
  defp status_tone("suspended"), do: :warn
  defp status_tone(_), do: :bad
end
