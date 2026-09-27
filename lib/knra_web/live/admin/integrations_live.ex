defmodule KnraWeb.Admin.IntegrationsLive do
  @moduledoc "KenTrade integration health and message log (M2)."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_integrations}}

  alias Knra.Integrations
  alias Knra.Integrations.KenTrade

  @cols "150px 150px 120px 90px 90px 1fr"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="integrations"
      wide
    >
      <.page_header title="Integrations">
        <:subtitle>
          Outbound: KenTrade PGA Container Enquiry API, queried on every RPM pass with the OCR-read container number.
          Inbound: KenTrade querying our container status API (<span class="font-mono">POST /api/kentrade/container-status</span>).
          Every request and response is logged here for dispute resolution.
        </:subtitle>
      </.page_header>

      <div class="mb-6 grid gap-4 md:grid-cols-4">
        <div class="rounded-md border border-line bg-white px-5 py-4">
          <div class="text-[11px] font-bold uppercase tracking-[0.06em] text-subtle">Status</div>
          <div class={[
            "mt-1 text-lg font-bold",
            if(@health.healthy?, do: "text-ok", else: "text-bad")
          ]}>
            {if @health.healthy?, do: "Healthy", else: "Last call failed"}
          </div>
        </div>
        <div class="rounded-md border border-line bg-white px-5 py-4">
          <div class="text-[11px] font-bold uppercase tracking-[0.06em] text-subtle">Mode</div>
          <div class="mt-1 text-lg font-bold">
            {if @config[:mock], do: "Mock (built-in)", else: "Live API"}
          </div>
          <div class="truncate text-xs text-muted">
            {@config[:base_url] || "KENTRADE_BASE_URL not set"}
          </div>
        </div>
        <div class="rounded-md border border-line bg-white px-5 py-4">
          <div class="text-[11px] font-bold uppercase tracking-[0.06em] text-subtle">
            Calls (24 h)
          </div>
          <div class="mt-1 text-lg font-bold">{@health.total}</div>
          <div class="text-xs text-muted">{@health.failures} failed</div>
        </div>
        <div class="rounded-md border border-line bg-white px-5 py-4">
          <div class="text-[11px] font-bold uppercase tracking-[0.06em] text-subtle">
            Last successful call
          </div>
          <div class="mt-1 text-lg font-bold">
            {(@health.last_ok && Knra.Time.format(@health.last_ok.inserted_at)) || "—"}
          </div>
          <div class="text-xs text-muted">Agency code: {@config[:agency_code] || "not set"}</div>
        </div>
      </div>

      <.form for={@filter} id="log-filter" phx-change="filter" class="mb-4 flex flex-wrap gap-3">
        <div class="min-w-64 flex-1">
          <.input field={@filter[:q]} placeholder="Container number" phx-debounce="300" />
        </div>
        <div class="w-60">
          <.input
            field={@filter[:system]}
            type="select"
            prompt="Both directions"
            options={[
              {"Outbound — container enquiry", "kentrade"},
              {"Inbound — status queries", "kentrade_inbound"}
            ]}
          />
        </div>
        <div class="w-52">
          <.input
            field={@filter[:outcome]}
            type="select"
            prompt="All outcomes"
            options={~w(ok found transit not_found invalid_request unauthorized forbidden error)}
          />
        </div>
      </.form>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Time</div>
          <div>Direction / containers</div>
          <div>Outcome</div>
          <div>HTTP</div>
          <div>Duration</div>
          <div>Message</div>
        </.thead>
        <div :for={l <- @logs} id={"log-#{l.id}"} class="border-b border-line-soft last:border-0">
          <div
            class="grid cursor-pointer items-center gap-1 px-5 py-2.5 text-[13px] hover:bg-panel md:gap-3"
            style={"--cols: #{@cols}"}
            phx-click="toggle"
            phx-value-id={l.id}
          >
            <div class="font-mono text-xs text-muted">{Knra.Time.format(l.inserted_at)}</div>
            <div class="min-w-0">
              <div class="text-[11px] font-bold uppercase text-subtle">
                {if l.system == "kentrade_inbound", do: "← Inbound", else: "→ Outbound"}
              </div>
              <div class="truncate font-mono text-xs">{l.object_ref}</div>
            </div>
            <div>
              <.pill tone={outcome_tone(l.outcome)}>{l.outcome}</.pill>
            </div>
            <div class="font-mono text-xs">{l.http_status || "—"}</div>
            <div class="font-mono text-xs">{l.duration_ms} ms</div>
            <div class="truncate text-muted">{log_message(l)}</div>
          </div>
          <div :if={@open == l.id} class="grid gap-3 bg-panel px-5 py-3 md:grid-cols-2">
            <div>
              <div class="mb-1 text-[11px] font-bold uppercase text-subtle">Request body</div>
              <pre class="overflow-x-auto rounded border border-line bg-white p-3 font-mono text-xs">{Jason.encode!(l.request, pretty: true)}</pre>
            </div>
            <div>
              <div class="mb-1 text-[11px] font-bold uppercase text-subtle">Parsed response</div>
              <pre class="max-h-96 overflow-auto rounded border border-line bg-white p-3 font-mono text-xs">{Jason.encode!(l.response, pretty: true)}</pre>
            </div>
          </div>
        </div>
        <.empty :if={@logs == []} text="No KenTrade calls logged yet." />
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Integrations", filters: %{}, open: nil, config: KenTrade.config())
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"filter" => f}, socket),
    do: {:noreply, socket |> assign(:filters, f) |> load()}

  def handle_event("toggle", %{"id" => id}, socket) do
    id = String.to_integer(id)
    {:noreply, assign(socket, :open, if(socket.assigns.open == id, do: nil, else: id))}
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    assign(socket,
      logs: Integrations.list_logs(socket.assigns.filters),
      health: Integrations.health("kentrade"),
      filter: to_form(socket.assigns.filters, as: :filter)
    )
  end

  defp outcome_tone("found"), do: :ok
  defp outcome_tone("ok"), do: :ok
  defp outcome_tone("transit"), do: :info
  defp outcome_tone("not_found"), do: :warn
  defp outcome_tone(_), do: :bad

  defp log_message(%{system: "kentrade_inbound", response: %{"items" => items}}) do
    items
    |> Enum.frequencies_by(& &1["status"])
    |> Enum.map_join(" · ", fn {s, n} -> "#{n} #{s}" end)
  end

  defp log_message(l), do: l.response["message"]
end
