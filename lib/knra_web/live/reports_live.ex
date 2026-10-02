defmodule KnraWeb.ReportsLive do
  @moduledoc """
  Maker–checker queue. Checking officers see applications awaiting a report;
  verification officers see reports awaiting verification.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_applications}}

  alias Knra.Screening
  alias Knra.Screening.Application

  @cols "160px 150px 1fr 170px 190px 90px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="reports"
    >
      <.page_header title="Screening Reports — Maker / Checker">
        <:subtitle>
          The checking officer drafts and submits the report; a different verification officer approves it.
          An approved report with a paid invoice clears the container and issues the certificate.
        </:subtitle>
      </.page_header>

      <div :for={{title, rows} <- @sections} class="mb-6">
        <h2 class="mb-2 text-sm font-bold text-muted">{title} ({length(rows)})</h2>
        <.card padded={false}>
          <.thead cols={@cols}>
            <div>Application</div>
            <div>Container</div>
            <div>Consignment</div>
            <div>Screening outcome</div>
            <div>Stage</div>
            <div></div>
          </.thead>
          <div
            :for={a <- rows}
            id={"report-#{a.reference}"}
            class="grid items-center gap-1 border-b border-line-soft px-5 py-3 text-[13px] last:border-0 md:gap-3"
            style={"--cols: #{@cols}"}
          >
            <div class="font-mono text-xs">{a.reference}</div>
            <div><.container_no number={a.container_number} class="text-xs" /></div>
            <div class="min-w-0 truncate text-muted">{a.goods_description || "—"}</div>
            <div class="font-semibold text-ok">{outcome(a)}</div>
            <div>
              <.stage_badge stage={a.stage} />
              <div :if={rejected?(a)} class="mt-1 text-xs text-bad">Returned for correction</div>
            </div>
            <div class="text-right">
              <.link navigate={~p"/applications/#{a.reference}"} class={btn(:secondary, :sm)}>
                Open
              </.link>
            </div>
          </div>
          <.empty :if={rows == []} text="Nothing pending." />
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Screening Reports") |> load()}
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    drafts = {"Awaiting Screening Report", Screening.list_by_stage("report_draft")}
    checks = {"Awaiting Verification", Screening.list_by_stage("report_check")}

    scope = socket.assigns.current_scope
    drafts? = Knra.Accounts.Policy.can?(scope, :draft_report)
    verifies? = Knra.Accounts.Policy.can?(scope, :verify_report)

    # Put the queue this user acts on first
    sections = if verifies? and not drafts?, do: [checks, drafts], else: [drafts, checks]

    assign(socket, :sections, sections)
  end

  defp outcome(%Application{alarmed: false}), do: "Clear pass"
  defp outcome(%Application{}), do: "Alarm resolved"

  defp rejected?(%Application{stage: "report_draft", reports: [%{status: "rejected"} | _]}),
    do: true

  defp rejected?(_), do: false
end
