defmodule KnraWeb.Reporting.ScreeningLive do
  @moduledoc "Screening Summary: containers screened in a period and where they stand."
  use KnraWeb, :live_view
  use KnraWeb.Reporting.Base, path: "/reporting/screening"

  alias Knra.Reporting
  alias Knra.Screening.Application

  @list_limit 200

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="report_screening"
      wide
    >
      <.report_filters filters={@filters} lanes={@lanes} export="screening" />
      <.report_header
        title="Screening Summary"
        filters={@filters}
        lane_name={@lane_name}
        generated_by={@current_scope.user.name}
      />

      <.figures items={[
        {"Containers screened", @r.totals.screened, "#{@r.totals.manual} recorded by RPM operators"},
        {"Cleared", @r.totals.cleared, pct(@r.totals.cleared, @r.totals.screened) <> " of screened"},
        {"Detained", @r.totals.detained,
         pct(@r.totals.detained, @r.totals.screened) <> " of screened"},
        {"In progress", @r.totals.in_progress, "awaiting a step"}
      ]} />
      <.figures items={[
        {"Alarm rate", pct(@r.totals.alarms, @r.totals.screened), "#{@r.totals.alarms} alarms"},
        {"Secondary inspection rate", pct(@r.totals.secondary, @r.totals.screened),
         "#{@r.totals.secondary} diverted"},
        {"Auto-approved", @r.totals.auto_approved, "no alarm, no report"},
        {"Flagged passes", @r.totals.flagged, "recorded without KenTrade"}
      ]} />

      <.report_section id="daily" title="Containers Screened per Day">
        <.daily_columns
          label="Containers screened"
          days={
            Enum.map(@r.daily, &%{date: &1.date, value: &1.screened, detail: "#{&1.alarms} alarms"})
          }
        />
      </.report_section>

      <div class="grid gap-x-6 lg:grid-cols-2">
        <.report_section id="statuses" title="Status of Screened Containers">
          <.bar_list rows={status_rows(@r.stages)} />
          <:note>Status as it stands now for containers screened in the period.</:note>
        </.report_section>

        <.report_section id="turnaround" title="Turnaround (median)">
          <dl class="grid grid-cols-[1fr_auto] gap-y-2.5 text-[13px]">
            <dt class="text-muted">RPM pass to clearance</dt>
            <dd class="text-right font-semibold tabular-nums">
              {duration(@r.turnaround.scan_to_clear)}
            </dd>
            <dt class="text-muted">RPM pass to CAS decision (alarms)</dt>
            <dd class="text-right font-semibold tabular-nums">
              {duration(@r.turnaround.alarm_to_decision)}
            </dd>
            <dt class="text-muted">Report submitted to verification decision</dt>
            <dd class="text-right font-semibold tabular-nums">
              {duration(@r.turnaround.verification)}
            </dd>
          </dl>
        </.report_section>
      </div>

      <.report_section id="by-lane" title="Containers by Lane">
        <div class="overflow-x-auto">
          <table class="w-full text-[13px] tabular-nums">
            <thead>
              <tr class="border-b border-line text-left text-xs text-muted">
                <th class="py-2 pr-4">Lane</th>
                <th class="py-2 pr-4 text-right">Screened</th>
                <th class="py-2 pr-4 text-right">Alarms</th>
                <th class="py-2 pr-4 text-right">Alarm rate</th>
                <th class="py-2 pr-4 text-right">Cleared</th>
                <th class="py-2 pr-4 text-right">Detained</th>
                <th class="py-2 text-right">In progress</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={l <- @r.lanes} class="border-b border-line-soft">
                <td class="py-2 pr-4">
                  {l.lane.name} <span class="text-xs text-subtle">· {l.lane.device_code}</span>
                </td>
                <td class="py-2 pr-4 text-right">{l.screened}</td>
                <td class="py-2 pr-4 text-right">{l.alarms}</td>
                <td class="py-2 pr-4 text-right text-muted">{pct(l.alarms, l.screened)}</td>
                <td class="py-2 pr-4 text-right">{l.cleared}</td>
                <td class="py-2 pr-4 text-right">{l.detained}</td>
                <td class="py-2 text-right">{l.in_progress}</td>
              </tr>
              <tr class="font-bold">
                <td class="py-2 pr-4 text-right">TOTAL</td>
                <td class="py-2 pr-4 text-right">{@r.totals.screened}</td>
                <td class="py-2 pr-4 text-right">{@r.totals.alarms}</td>
                <td class="py-2 pr-4 text-right text-muted">
                  {pct(@r.totals.alarms, @r.totals.screened)}
                </td>
                <td class="py-2 pr-4 text-right">{@r.totals.cleared}</td>
                <td class="py-2 pr-4 text-right">{@r.totals.detained}</td>
                <td class="py-2 text-right">{@r.totals.in_progress}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.report_section>

      <div class="grid gap-x-6 lg:grid-cols-2">
        <.report_section id="fees" title="Screening Fees">
          <dl class="grid grid-cols-[1fr_auto] gap-y-2.5 text-[13px] tabular-nums">
            <dt class="text-muted">Invoices raised</dt>
            <dd class="text-right">{@r.revenue.invoices} · KES {money(@r.revenue.raised_kes)}</dd>
            <dt class="text-muted">Paid</dt>
            <dd class="text-right">{@r.revenue.paid} · KES {money(@r.revenue.paid_kes)}</dd>
            <dt class="text-muted">Outstanding</dt>
            <dd class="text-right font-semibold">KES {money(@r.revenue.outstanding_kes)}</dd>
          </dl>
          <dl class="mt-2.5 grid grid-cols-[1fr_auto] gap-y-2.5 text-[13px] tabular-nums">
            <%= for {method, label} <- [{"mpesa", "M-Pesa payments"}, {"bank", "Bank transfers"}] do %>
              <dt class="text-muted">{label}</dt>
              <dd class="text-right">
                {(@r.revenue.methods[method] || %{count: 0}).count} · KES {money(
                  (@r.revenue.methods[method] || %{kes: Decimal.new(0)}).kes
                )}
              </dd>
            <% end %>
          </dl>
        </.report_section>

        <.report_section id="recorded" title="How Containers Were Recorded">
          <.bar_list rows={[
            {"RPM feed", @r.totals.screened - @r.totals.manual},
            {"RPM operator (manual)", @r.totals.manual},
            {"  of which flagged for review", @r.totals.flagged}
          ]} />
        </.report_section>
      </div>

      <.report_section id="containers" title={"Containers Screened (#{@r.totals.screened})"}>
        <div class="overflow-x-auto">
          <table class="w-full text-[12px]">
            <thead>
              <tr class="border-b border-line text-left text-xs text-muted">
                <th class="py-2 pr-3">Application</th>
                <th class="py-2 pr-3">Container</th>
                <th class="py-2 pr-3">Scanned</th>
                <th class="py-2 pr-3">Lane</th>
                <th class="py-2 pr-3">Alarm</th>
                <th class="py-2 pr-3">Importer</th>
                <th class="py-2 pr-3">Fee</th>
                <th class="py-2 pr-3">Status</th>
                <th class="py-2">Certificate</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows} class="border-b border-line-soft align-top">
                <td class="py-1.5 pr-3">
                  <.link navigate={~p"/applications/#{row.reference}"} class="font-mono text-brand">
                    {row.reference}
                  </.link>
                </td>
                <td class="py-1.5 pr-3 font-mono">{Application.display_container(row.container)}</td>
                <td class="py-1.5 pr-3 whitespace-nowrap text-muted">
                  {Knra.Time.format(row.scanned_at)}
                </td>
                <td class="py-1.5 pr-3">{row.lane}</td>
                <td class="py-1.5 pr-3">{if row.alarmed, do: "Yes", else: "—"}</td>
                <td class="py-1.5 pr-3">{row.importer || "—"}</td>
                <td class="py-1.5 pr-3">
                  {row.invoice_status && String.capitalize(row.invoice_status)}
                </td>
                <td class="py-1.5 pr-3">{Application.stage_label(row.stage)}</td>
                <td class="py-1.5 font-mono">{row.certificate || "—"}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <:note :if={@r.totals.screened > length(@rows)}>
          Showing the latest {length(@rows)} of {@r.totals.screened}. The CSV download has every container.
        </:note>
      </.report_section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, :page_title, "Screening Summary")}

  defp load_report(socket) do
    f = socket.assigns.filters

    assign(socket,
      r: Reporting.screening_summary(f),
      rows: Reporting.screening_rows(f, @list_limit)
    )
  end

  defp status_rows(stages) do
    ~w(alarm secondary report_draft report_check approved cleared detained)
    |> Enum.map(&{Application.stage_label(&1), Map.get(stages, &1, 0)})
  end
end
