defmodule KnraWeb.LanesLive do
  @moduledoc "CAS lane overview: live RPM lane status, today's counts and recent occupancies."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_lanes}}

  alias Knra.{Devices, Screening}
  alias Knra.Devices.Lane

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav_counts={@nav_counts} active="lanes">
      <.page_header title="Central Alarm Station — Mombasa">
        <:subtitle>
          Live RPM lane status. On an RPM pass the lane camera reads the container number by OCR,
          KenTrade is queried for the consignment and a screening-fee invoice is raised.
          Occupancies that alarm appear in the alarm queue.
        </:subtitle>
        <:actions :if={Knra.Simulator.enabled?()}>
          <.link navigate={~p"/simulator"} class={btn(:outline)}>Simulate RPM pass</.link>
        </:actions>
      </.page_header>

      <div class="mb-6 grid grid-cols-2 gap-4 md:grid-cols-4">
        <div
          :for={{label, value, tone} <- stat_tiles(@stats, @nav_counts)}
          class="rounded-md border border-line bg-white px-5 py-4"
        >
          <div class="text-[11px] font-bold uppercase tracking-[0.06em] text-subtle">{label}</div>
          <div class={["mt-1 text-2xl font-bold", tone]}>{value}</div>
        </div>
      </div>

      <div id="lanes" class="mb-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <div
          :for={lane <- @lanes}
          id={"lane-#{lane.id}"}
          class={[
            "rounded-md border border-line border-t-4 bg-white p-[18px]",
            if(lane.in_service, do: "border-t-ok", else: "border-t-warn")
          ]}
        >
          <div class="mb-2.5 flex items-center justify-between">
            <div class="text-base font-bold">{lane.name}</div>
            <.pill tone={if(lane.in_service, do: :ok, else: :warn)}>
              {if lane.in_service, do: "In service", else: "Out of service"}
            </.pill>
          </div>
          <div class="text-xs leading-relaxed text-muted">
            <div>{lane.device_code} / {lane.serial_number}</div>
            <div>{lane.detector_type}</div>
            <div>
              {if lane.in_service,
                do: "Ready · background nominal",
                else: lane.status_reason || "Traffic rerouted"}
            </div>
            <div class={[
              Lane.calibration_overdue?(lane) && "font-semibold text-bad",
              Lane.calibration_due_soon?(lane) && "font-semibold text-warn"
            ]}>
              Calibration due {Knra.Time.format_date(lane.calibration_due_on)}
            </div>
          </div>
        </div>
      </div>

      <div class="grid gap-5 lg:grid-cols-2">
        <.card title="Alarm queue" padded={false}>
          <:actions>
            <.link navigate={~p"/cas/alarms"} class="text-xs font-semibold text-brand">
              Open queue →
            </.link>
          </:actions>
          <div
            :for={a <- @alarms}
            class="flex items-center gap-3.5 border-b border-line-soft px-5 py-3 last:border-0"
          >
            <span class="size-2 flex-none rounded-full bg-bad"></span>
            <div class="min-w-0 flex-1">
              <.container_no number={a.container_number} class="text-[13px]" />
              <div class="text-xs text-muted">
                {a.lane.name} · gamma {a.gamma_cps} cps · waiting {Knra.Time.ago(a.scanned_at)}
              </div>
            </div>
            <.link navigate={~p"/applications/#{a.reference}"} class={btn(:secondary, :sm)}>
              Adjudicate
            </.link>
          </div>
          <.empty :if={@alarms == []} text="No alarms awaiting adjudication." />
        </.card>

        <.card title="Recent occupancies" padded={false}>
          <div
            :for={a <- @recent}
            class="flex items-center gap-3.5 border-b border-line-soft px-5 py-3 last:border-0"
          >
            <span class={["size-2 flex-none rounded-full", if(a.alarmed, do: "bg-bad", else: "bg-ok")]}>
            </span>
            <div class="min-w-0 flex-1">
              <.container_no number={a.container_number} class="text-[13px]" />
              <div class="text-xs text-muted">
                {a.lane.name} · {Knra.Time.format(a.scanned_at)} · {if a.alarmed,
                  do: "Radiation alarm",
                  else: "No alarm"}
              </div>
            </div>
            <.stage_badge stage={a.stage} />
            <.link navigate={~p"/applications/#{a.reference}"} class={btn(:secondary, :sm)}>
              View
            </.link>
          </div>
          <.empty :if={@recent == []} text="No occupancies recorded yet." />
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Lane overview") |> load()}
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:lane_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    assign(socket,
      lanes: Devices.list_lanes(),
      recent: Screening.recent_occupancies(8),
      alarms: Screening.list_by_stage("alarm") |> Enum.take(5),
      stats: Screening.today_stats()
    )
  end

  defp stat_tiles(stats, counts) do
    [
      {"Screened today", stats.screened, "text-ink"},
      {"Alarms today", stats.alarms, if(stats.alarms > 0, do: "text-bad", else: "text-ink")},
      {"Awaiting adjudication", counts["alarms"],
       if(counts["alarms"] > 0, do: "text-bad", else: "text-ink")},
      {"Cleared today", stats.cleared, "text-ok"}
    ]
  end
end
