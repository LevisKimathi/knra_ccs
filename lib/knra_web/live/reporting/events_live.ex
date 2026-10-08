defmodule KnraWeb.Reporting.EventsLive do
  @moduledoc """
  Events Report: RPM events by lane in a period, laid out like the CAS vendor's
  system report: occupancies and alarms, alarm types, dispositions, secondary
  inspections and device faults.
  """
  use KnraWeb, :live_view
  use KnraWeb.Reporting.Base, path: "/reporting/events"

  alias Knra.Reporting

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="report_events"
      wide
    >
      <.report_filters filters={@filters} lanes={@lanes} export="events" />
      <.report_header
        title="Events Report"
        filters={@filters}
        lane_name={@lane_name}
        generated_by={@current_scope.user.name}
      />

      <.figures items={[
        {"Occupancies", @t.occupancies, "#{@t.manual} recorded by RPM operators"},
        {"Total alarms", @t.alarms, pct(@t.alarms, @t.occupancies) <> " of occupancies"},
        {"Active alarms", @t.active, "awaiting CAS adjudication"},
        {"Released alarms", @t.released, "#{@t.secondary} diverted, #{@t.detained} detained"}
      ]} />

      <.report_section id="events-by-lane" title="Details of Events by Lane">
        <div class="overflow-x-auto">
          <table class="w-full text-[13px] tabular-nums">
            <thead>
              <tr class="border-b border-line text-left text-xs text-muted">
                <th class="py-2 pr-4">Lane</th>
                <th class="py-2 pr-3 text-right">Occupancies</th>
                <th class="py-2 pr-3 text-right">By operator</th>
                <th class="py-2 pr-3 text-right">Total alarms</th>
                <th class="py-2 pr-3 text-right">Active</th>
                <th class="py-2 pr-3 text-right">Released</th>
                <th class="py-2 pr-3 text-right">To secondary</th>
                <th class="py-2 pr-3 text-right">Detained</th>
                <th class="py-2 text-right">Prior open</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={l <- @r.lanes} class="border-b border-line-soft">
                <td class="py-2 pr-4">
                  {l.lane.name} <span class="text-xs text-subtle">· {l.lane.device_code}</span>
                </td>
                <td class="py-2 pr-3 text-right">{l.occupancies}</td>
                <td class="py-2 pr-3 text-right">{l.manual}</td>
                <td class="py-2 pr-3 text-right">{l.alarms}</td>
                <td class="py-2 pr-3 text-right">{l.active}</td>
                <td class="py-2 pr-3 text-right">{l.released}</td>
                <td class="py-2 pr-3 text-right">{l.secondary}</td>
                <td class="py-2 pr-3 text-right">{l.detained}</td>
                <td class="py-2 text-right">{l.prior_open}</td>
              </tr>
              <tr class="font-bold">
                <td class="py-2 pr-4 text-right">TOTAL</td>
                <td class="py-2 pr-3 text-right">{@t.occupancies}</td>
                <td class="py-2 pr-3 text-right">{@t.manual}</td>
                <td class="py-2 pr-3 text-right">{@t.alarms}</td>
                <td class="py-2 pr-3 text-right">{@t.active}</td>
                <td class="py-2 pr-3 text-right">{@t.released}</td>
                <td class="py-2 pr-3 text-right">{@t.secondary}</td>
                <td class="py-2 pr-3 text-right">{@t.detained}</td>
                <td class="py-2 text-right">{@t.prior_open}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <:note>
          Active = still awaiting CAS adjudication now. Prior open = alarms raised before the period that
          were still unadjudicated when it began.
        </:note>
      </.report_section>

      <.report_section id="alarm-types" title="Types of Alarms">
        <div class="grid gap-6 lg:grid-cols-[3fr_2fr]">
          <div class="overflow-x-auto">
            <table class="w-full text-[13px] tabular-nums">
              <thead>
                <tr class="border-b border-line text-left text-xs text-muted">
                  <th class="py-2 pr-4">Lane</th>
                  <th class="py-2 pr-3 text-right">Gamma</th>
                  <th class="py-2 pr-3 text-right">Neutron</th>
                  <th class="py-2 pr-3 text-right">Gamma + neutron</th>
                  <th class="py-2 pr-3 text-right">Operator-reported</th>
                  <th class="py-2 text-right">Total</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={l <- @r.lanes} class="border-b border-line-soft">
                  <td class="py-2 pr-4">{l.lane.name}</td>
                  <td class="py-2 pr-3 text-right">{l.types.gamma}</td>
                  <td class="py-2 pr-3 text-right">{l.types.neutron}</td>
                  <td class="py-2 pr-3 text-right">{l.types.both}</td>
                  <td class="py-2 pr-3 text-right">{l.types.operator}</td>
                  <td class="py-2 text-right">{l.alarms}</td>
                </tr>
                <tr class="font-bold">
                  <td class="py-2 pr-4 text-right">TOTAL</td>
                  <td class="py-2 pr-3 text-right">{@types.gamma}</td>
                  <td class="py-2 pr-3 text-right">{@types.neutron}</td>
                  <td class="py-2 pr-3 text-right">{@types.both}</td>
                  <td class="py-2 pr-3 text-right">{@types.operator}</td>
                  <td class="py-2 text-right">{@t.alarms}</td>
                </tr>
              </tbody>
            </table>
          </div>
          <.bar_list
            rows={[
              {"Gamma", @types.gamma},
              {"Neutron", @types.neutron},
              {"Gamma + neutron", @types.both},
              {"Operator-reported", @types.operator}
            ]}
            empty="No alarms in this period."
          />
        </div>
        <:note>
          Gamma above 100 cps or neutron above 5 cps over background. Operator-reported = alarm recorded by
          an RPM operator without a RIID reading above those thresholds.
        </:note>
      </.report_section>

      <.report_section id="dispositions" title="Alarm Dispositions">
        <div class="grid gap-6 lg:grid-cols-2">
          <.bar_list rows={@r.disposition_totals} empty="No alarms adjudicated in this period." />
          <div :if={@r.dispositions != []} class="overflow-x-auto">
            <table class="w-full text-[13px] tabular-nums">
              <%= for {lane, rows} <- @r.dispositions do %>
                <tr class="border-b border-line bg-panel text-xs font-bold text-muted">
                  <td class="py-1.5 pr-3">{lane.name} disposition</td>
                  <td class="py-1.5 text-right">Alarms</td>
                </tr>
                <tr :for={{classification, n} <- rows} class="border-b border-line-soft">
                  <td class="py-1.5 pr-3">{classification}</td>
                  <td class="py-1.5 text-right">{n}</td>
                </tr>
              <% end %>
            </table>
          </div>
        </div>
        <:note>CAS classifications recorded at adjudication, for alarms raised in the period.</:note>
      </.report_section>

      <.report_section id="inspections" title="Secondary Inspections">
        <div class="grid gap-6 lg:grid-cols-2">
          <div>
            <h3 class="mb-2 text-xs font-bold uppercase tracking-wide text-muted">Outcome</h3>
            <.bar_list
              rows={inspection_outcomes(@r.inspections)}
              empty="No secondary inspections in this period."
            />
          </div>
          <div>
            <h3 class="mb-2 text-xs font-bold uppercase tracking-wide text-muted">
              Isotope identified (RIID)
            </h3>
            <.bar_list
              rows={inspection_isotopes(@r.inspections)}
              empty="No secondary inspections in this period."
            />
          </div>
        </div>
      </.report_section>

      <div class="grid gap-x-6 lg:grid-cols-2">
        <.report_section id="faults-by-lane" title="Device Faults by Lane">
          <table class="w-full text-[13px] tabular-nums">
            <thead>
              <tr class="border-b border-line text-left text-xs text-muted">
                <th class="py-2 pr-3">Lane</th>
                <th class="py-2 pr-3 text-right">Faults opened</th>
                <th class="py-2 pr-3 text-right">Returned to service</th>
                <th class="py-2 text-right">Out of service now</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={l <- @r.faults.lanes} class="border-b border-line-soft">
                <td class="py-2 pr-3">{l.lane.name}</td>
                <td class="py-2 pr-3 text-right">{l.opened}</td>
                <td class="py-2 pr-3 text-right">{l.cleared}</td>
                <td class="py-2 text-right">{if l.active > 0, do: "Yes", else: "—"}</td>
              </tr>
              <tr class="font-bold">
                <td class="py-2 pr-3 text-right">TOTAL</td>
                <td class="py-2 pr-3 text-right">
                  {Enum.sum(Enum.map(@r.faults.lanes, & &1.opened))}
                </td>
                <td class="py-2 pr-3 text-right">
                  {Enum.sum(Enum.map(@r.faults.lanes, & &1.cleared))}
                </td>
                <td class="py-2 text-right">{Enum.sum(Enum.map(@r.faults.lanes, & &1.active))}</td>
              </tr>
            </tbody>
          </table>
        </.report_section>

        <.report_section id="fault-reasons" title="Device Faults by Reason">
          <.bar_list rows={@r.faults.reasons} empty="No device faults recorded in this period." />
          <:note>Reasons as entered when a lane was taken out of service.</:note>
        </.report_section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Events Report")}

  defp load_report(socket) do
    r = Reporting.events_report(socket.assigns.filters)
    sum = fn key -> r.lanes |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sum() end
    sum_type = fn key -> r.lanes |> Enum.map(&Map.fetch!(&1.types, key)) |> Enum.sum() end

    assign(socket,
      r: r,
      t:
        Map.new(
          ~w(occupancies manual alarms active released secondary detained prior_open)a,
          &{&1, sum.(&1)}
        ),
      types: Map.new(~w(gamma neutron both operator)a, &{&1, sum_type.(&1)})
    )
  end

  defp inspection_outcomes(rows) do
    totals =
      Enum.reduce(rows, %{}, fn {outcome, _iso, n}, acc ->
        Map.update(acc, outcome, n, &(&1 + n))
      end)

    [
      {"No objection", Map.get(totals, "no_objection", 0)},
      {"Detention recommended", Map.get(totals, "detain", 0)}
    ]
  end

  defp inspection_isotopes(rows) do
    rows
    |> Enum.reduce(%{}, fn {_outcome, iso, n}, acc -> Map.update(acc, iso, n, &(&1 + n)) end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end
end
