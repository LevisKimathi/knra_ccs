defmodule KnraWeb.Admin.AuditLive do
  @moduledoc "Append-only, hash-chained audit trail with search, chain verification and CSV export (M10)."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_audit}}

  alias Knra.Audit

  @cols "150px 150px 160px 1fr"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="audit"
      wide
    >
      <.page_header title="Audit trail">
        <:subtitle>
          Append-only: the database rejects edits and deletions, and each entry carries the hash of the one
          before it, so tampering breaks the chain. {@total} entries.
        </:subtitle>
        <:actions>
          <button id="verify-chain" phx-click="verify" class={btn(:secondary, :sm)}>
            <.icon name="hero-shield-check" class="size-4" /> Verify integrity
          </button>
          <.link href={~p"/admin/audit/export?#{@filters}"} class={btn(:outline, :sm)}>
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export CSV
          </.link>
        </:actions>
      </.page_header>

      <div
        :if={@chain}
        class={[
          "mb-4 rounded-md border px-5 py-3 text-sm",
          if(@chain == :ok,
            do: "border-ok/30 bg-ok-soft text-ok",
            else: "border-bad/30 bg-bad-soft text-bad"
          )
        ]}
      >
        <%= if @chain == :ok do %>
          <strong>Chain intact.</strong>
          All {@total} entries verified at {Knra.Time.format(Knra.Time.now())}.
        <% else %>
          <strong>Chain broken at entry #{elem(@chain, 1)}.</strong>
          The audit log has been altered outside the application.
        <% end %>
      </div>

      <.form
        for={@filter}
        id="audit-filter"
        phx-change="filter"
        class="mb-4 grid gap-3 sm:grid-cols-[1fr_200px_180px_160px_160px]"
      >
        <.input field={@filter[:q]} placeholder="Object, action or note" phx-debounce="300" />
        <.input field={@filter[:actor]} placeholder="Actor" phx-debounce="300" />
        <.input
          field={@filter[:object_type]}
          type="select"
          prompt="All objects"
          options={[
            {"Application", "application"},
            {"Payment", "payment"},
            {"User", "user"},
            {"Device", "device"},
            {"Fee schedule", "fee_schedule"}
          ]}
        />
        <.input field={@filter[:from]} type="date" />
        <.input field={@filter[:to]} type="date" />
      </.form>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Timestamp</div>
          <div>Object</div>
          <div>Actor</div>
          <div>Action / reason</div>
        </.thead>
        <div
          :for={e <- @entries}
          id={"audit-#{e.id}"}
          class="grid gap-1 border-b border-line-soft px-5 py-2.5 text-[13px] last:border-0 md:gap-3"
          style={"--cols: #{@cols}"}
        >
          <div class="font-mono text-xs text-muted">{Knra.Time.format(e.inserted_at)}</div>
          <div class="font-mono text-xs">
            <.link
              :if={e.object_type == "application"}
              navigate={~p"/applications/#{e.object_ref}"}
              class="text-brand"
            >
              {e.object_ref}
            </.link>
            <span :if={e.object_type != "application"}>{e.object_ref}</span>
          </div>
          <div>{e.actor_name}</div>
          <div>
            {e.action}<span :if={e.note} class="text-muted"> — {e.note}</span>
          </div>
        </div>
        <.empty :if={@entries == []} text="No entries match." />
      </.card>
      <p class="mt-3 text-xs text-subtle">
        Showing the latest {length(@entries)} matching entries. Export for the full set.
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Audit trail", filters: %{}, chain: nil) |> load()}
  end

  @impl true
  def handle_event("filter", %{"filter" => f}, socket),
    do: {:noreply, socket |> assign(:filters, f) |> load()}

  def handle_event("verify", _, socket),
    do: {:noreply, assign(socket, :chain, Audit.verify_chain())}

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    assign(socket,
      entries: Audit.search(socket.assigns.filters, 300),
      total: Audit.entry_count(),
      filter: to_form(socket.assigns.filters, as: :filter)
    )
  end
end
