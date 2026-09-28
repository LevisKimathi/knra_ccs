defmodule KnraWeb.Admin.ApiClientsLive do
  @moduledoc """
  Organisations allowed to call the container status API. Each gets its own
  client code, username and password; the password is shown once.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :manage_api_clients}}

  alias Knra.ApiClients

  @cols "1fr 130px 150px 190px 100px 300px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="api_clients"
    >
      <.page_header title="API Clients">
        <:subtitle>
          Organisations that may query container screening status via <span class="font-mono">POST {KnraWeb.Endpoint.path("/api/container-status")}</span>.
          Each has its own credentials and can be revoked on its own.
        </:subtitle>
        <:actions>
          <button :if={!@form} id="add-client" phx-click="new" class={btn(:primary, :sm)}>
            Add client
          </button>
        </:actions>
      </.page_header>

      <div
        :if={@issued}
        id="issued-credentials"
        class="mb-5 rounded-md border border-warn/30 bg-warn-soft px-5 py-4 text-sm"
      >
        <div class="mb-2 font-bold text-warn">
          Credentials for {@issued.name} — copy them now, the password is not shown again
        </div>
        <dl class="grid gap-x-6 gap-y-1 font-mono text-[13px] sm:grid-cols-[140px_1fr]">
          <dt class="text-muted">Username</dt>
          <dd>{@issued.username}</dd>
          <dt class="text-muted">Password</dt>
          <dd class="break-all">{@issued.password}</dd>
        </dl>
        <p class="mt-2 text-xs text-muted">
          The client sends <span class="font-mono">Authorization: Basic &lt;sha256 hex of username:password&gt;</span>;
          these credentials alone identify {@issued.name}. Share the password over a separate channel from the username.
        </p>
        <button phx-click="dismiss" class={[btn(:secondary, :sm), "mt-3"]}>I have saved these</button>
      </div>

      <.card :if={@form} title="Add API Client" class="mb-5">
        <.form for={@form} id="client-form" phx-change="validate" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-3">
            <.input
              field={@form[:name]}
              label="Organisation"
              placeholder="e.g. Kenya Trade Network Agency"
            />
            <.input
              field={@form[:client_code]}
              label="Client ID"
              placeholder="e.g. KENTRADE"
            />
            <.input field={@form[:username]} label="Username" placeholder="e.g. kentrade" />
          </div>
          <p class="mb-3 text-xs text-muted">
            A strong password is generated and shown once after saving.
          </p>
          <div class="flex gap-2">
            <button type="submit" class={btn(:primary, :sm)} phx-disable-with="Saving…">
              Create credentials
            </button>
            <button type="button" phx-click="cancel" class={btn(:secondary, :sm)}>Cancel</button>
          </div>
        </.form>
      </.card>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Organisation</div>
          <div>Client ID</div>
          <div>Username</div>
          <div>Last call / IP</div>
          <div>Status</div>
          <div></div>
        </.thead>
        <div
          :for={c <- @clients}
          id={"client-#{c.id}"}
          class="grid items-center gap-1 border-b border-line-soft px-5 py-3 text-[13px] last:border-0 md:gap-3"
          style={"--cols: #{@cols}"}
        >
          <div class="font-semibold">{c.name}</div>
          <div class="font-mono text-xs">{c.client_code}</div>
          <div class="font-mono text-xs">{c.username}</div>
          <div class="text-xs text-muted">
            {Knra.Time.format(c.last_used_at)}
            <div :if={c.last_used_ip} class="font-mono">{c.last_used_ip}</div>
          </div>
          <div>
            <.pill tone={if(c.status == "active", do: :ok, else: :bad)}>
              {if c.status == "active", do: "Active", else: "Revoked"}
            </.pill>
          </div>
          <div class="flex flex-wrap justify-end gap-1.5">
            <.link
              navigate={~p"/admin/audit?#{%{object_type: "api_client", q: c.client_code}}"}
              class={btn(:secondary, :sm)}
            >
              Activity
            </.link>
            <button
              :if={c.status == "active"}
              phx-click="reset"
              phx-value-id={c.id}
              data-confirm={"Issue a new password for #{c.name}? The current one stops working immediately."}
              class={btn(:secondary, :sm)}
            >
              New password
            </button>
            <button
              :if={c.status == "active"}
              phx-click="status"
              phx-value-id={c.id}
              phx-value-status="revoked"
              data-confirm={"Revoke API access for #{c.name}?"}
              class={btn(:danger, :sm)}
            >
              Revoke
            </button>
            <button
              :if={c.status == "revoked"}
              phx-click="status"
              phx-value-id={c.id}
              phx-value-status="active"
              class={btn(:ok, :sm)}
            >
              Restore
            </button>
          </div>
        </div>
        <.empty
          :if={@clients == []}
          text="No API clients yet. Add one to give an organisation access."
        />
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "API Clients", form: nil, issued: nil) |> load()}
  end

  @impl true
  def handle_event("new", _, socket),
    do: {:noreply, assign(socket, form: to_form(ApiClients.change_client()), issued: nil)}

  def handle_event("cancel", _, socket), do: {:noreply, assign(socket, :form, nil)}
  def handle_event("dismiss", _, socket), do: {:noreply, assign(socket, :issued, nil)}

  def handle_event("validate", %{"client" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(ApiClients.change_client(%ApiClients.Client{}, params), action: :validate)
     )}
  end

  def handle_event("save", %{"client" => params}, socket) do
    case ApiClients.create_client(socket.assigns.current_scope, params) do
      {:ok, client, password} ->
        {:noreply, socket |> assign(form: nil, issued: issued(client, password)) |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  def handle_event("reset", %{"id" => id}, socket) do
    case ApiClients.reset_credentials(socket.assigns.current_scope, ApiClients.get_client!(id)) do
      {:ok, client, password} ->
        {:noreply, socket |> assign(issued: issued(client, password)) |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  def handle_event("status", %{"id" => id, "status" => status}, socket) do
    case ApiClients.set_status(socket.assigns.current_scope, ApiClients.get_client!(id), status) do
      {:ok, c} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{c.name}: API access #{if status == "revoked", do: "revoked", else: "restored"}."
         )
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  defp issued(client, password),
    do: %{
      name: client.name,
      client_code: client.client_code,
      username: client.username,
      password: password
    }

  defp load(socket), do: assign(socket, :clients, ApiClients.list_clients())
end
