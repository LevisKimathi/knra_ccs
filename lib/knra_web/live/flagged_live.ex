defmodule KnraWeb.FlaggedLive do
  @moduledoc """
  RPM passes recorded without KenTrade confirmation (not found, transit, or
  KenTrade unavailable), waiting for a supervisor to review them.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :review_flagged}}

  alias Knra.Screening

  @cols "150px 140px 1fr 180px 110px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="flagged"
    >
      <.page_header title="Flagged Passes">
        <:subtitle>
          RPM passes recorded by an operator without KenTrade confirmation. Check each reason, then
          mark it reviewed on the application page.
        </:subtitle>
      </.page_header>

      <div class="mb-4 flex gap-2">
        <.link
          :for={{key, label} <- [{"pending", "Awaiting Review"}, {"reviewed", "Reviewed"}]}
          patch={~p"/reviews?#{%{status: key}}"}
          class={btn(if(@status == key, do: :primary, else: :secondary), :sm)}
        >
          {label}
        </.link>
      </div>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Container</div>
          <div>Recorded</div>
          <div>Reason</div>
          <div>KenTrade now</div>
          <div>Stage</div>
        </.thead>
        <.link
          :for={a <- @apps}
          navigate={~p"/applications/#{a.reference}"}
          id={"flagged-#{a.reference}"}
          class="grid items-start gap-1 border-b border-line-soft px-5 py-3 text-[13px] last:border-0 hover:bg-panel md:gap-3"
          style={"--cols: #{@cols}"}
        >
          <div>
            <.container_no number={a.container_number} class="text-xs" />
            <div class="text-xs text-subtle">{a.reference}</div>
          </div>
          <div class="text-xs text-muted">
            {Knra.Time.format(a.scanned_at)}<br />{a.recorded_by && a.recorded_by.name}
          </div>
          <div class="min-w-0">
            <div class="break-words">{a.override_reason}</div>
            <div :if={a.review_status == "reviewed"} class="mt-1 text-xs text-muted">
              Reviewed by {a.reviewed_by && a.reviewed_by.name}{a.review_note && " — #{a.review_note}"}
            </div>
          </div>
          <div>
            <.pill tone={if(a.lookup_status == "found", do: :ok, else: :warn)}>
              {KnraWeb.ApplicationLive.Show.lookup_label(a.lookup_status)}
            </.pill>
          </div>
          <div><.stage_badge stage={a.stage} /></div>
        </.link>
        <.empty
          :if={@apps == []}
          text={
            if @status == "pending", do: "Nothing awaiting review.", else: "No reviewed passes yet."
          }
        />
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Flagged Passes")}

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] == "reviewed", do: "reviewed", else: "pending"
    {:noreply, socket |> assign(:status, status) |> load()}
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket), do: assign(socket, :apps, Screening.list_flagged(socket.assigns.status))
end
