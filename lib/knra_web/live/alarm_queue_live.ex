defmodule KnraWeb.AlarmQueueLive do
  @moduledoc "Every RPM alarm awaiting CAS adjudication, oldest first."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_lanes}}

  alias Knra.Screening

  @cols "150px 130px 1fr 130px 110px 110px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="alarms"
    >
      <.page_header title="Alarm queue">
        <:subtitle>
          Every alarm must be adjudicated with a classification and a recorded reason. Unresolved
          alarms block the container at the divert bay. Alarms waiting longer than {@sla} minutes are flagged.
        </:subtitle>
      </.page_header>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Container</div>
          <div>Lane / time</div>
          <div>Consignment</div>
          <div>Detector</div>
          <div>Waiting</div>
          <div></div>
        </.thead>
        <div
          :for={a <- @alarms}
          id={"alarm-#{a.reference}"}
          class="grid items-center gap-1 border-b border-line-soft px-5 py-3.5 text-[13px] last:border-0 md:gap-3"
          style={"--cols: #{@cols}"}
        >
          <div>
            <.container_no number={a.container_number} class="text-xs" />
            <div class="text-xs text-subtle">{a.reference}</div>
          </div>
          <div class="text-xs text-muted">{a.lane.name}<br />{Knra.Time.format(a.scanned_at)}</div>
          <div class="text-muted">
            {a.goods_description || lookup_text(a)}
            <div :if={a.importer_name} class="text-xs text-subtle">{a.importer_name}</div>
          </div>
          <div class="text-xs font-bold text-bad">
            Gamma {a.gamma_cps} cps<br /><span class="font-normal text-muted">
              Neutron {a.neutron_cps} cps
            </span>
          </div>
          <div>
            <.pill tone={if(Knra.Time.minutes_since(a.scanned_at) > @sla, do: :bad, else: :warn)}>
              {Knra.Time.ago(a.scanned_at)}
            </.pill>
          </div>
          <div class="text-right">
            <.link navigate={~p"/applications/#{a.reference}"} class={btn(:secondary, :sm)}>
              Adjudicate
            </.link>
          </div>
        </div>
        <.empty :if={@alarms == []} text="No alarms awaiting adjudication." />
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(30_000, :tick)

    {:ok,
     socket
     |> assign(page_title: "Alarm queue", sla: Screening.alarm_sla_minutes())
     |> load()}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket), do: assign(socket, :alarms, Screening.list_by_stage("alarm"))

  defp lookup_text(%{lookup_status: "pending"}), do: "KenTrade lookup in progress…"
  defp lookup_text(%{lookup_status: "transit"}), do: "Transit cargo — no consignment details"
  defp lookup_text(_), do: "Consignment details unavailable"
end
