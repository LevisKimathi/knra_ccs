defmodule KnraWeb.ApplicationLive.Index do
  @moduledoc "Search every screening application by container, reference, importer or invoice."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_applications}}

  alias Knra.Screening
  alias Knra.Screening.Application

  @cols "150px 140px 1fr 150px 90px 200px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="applications"
    >
      <.page_header title="Screening Applications">
        <:subtitle>One application is opened for every RPM occupancy.</:subtitle>
      </.page_header>

      <.form for={@filter} id="filter-form" phx-change="filter" class="mb-4 flex flex-wrap gap-3">
        <div class="min-w-64 flex-1">
          <.input
            field={@filter[:q]}
            placeholder="Container, CCS reference, importer or invoice number"
            phx-debounce="300"
          />
        </div>
        <div class="w-60">
          <.input
            field={@filter[:stage]}
            type="select"
            prompt="All stages"
            options={Enum.map(Application.stages(), &{Application.stage_label(&1), &1})}
          />
        </div>
      </.form>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Container</div>
          <div>Scanned</div>
          <div>Consignment</div>
          <div>Invoice</div>
          <div>Fee</div>
          <div>Stage</div>
        </.thead>
        <.link
          :for={a <- @apps}
          navigate={~p"/applications/#{a.reference}"}
          id={"app-#{a.reference}"}
          class="grid items-center gap-1 border-b border-line-soft px-5 py-3 text-[13px] last:border-0 hover:bg-panel md:gap-3"
          style={"--cols: #{@cols}"}
        >
          <div>
            <.container_no number={a.container_number} class="text-xs" />
            <div class="text-xs text-subtle">{a.reference}</div>
          </div>
          <div class="text-xs text-muted">{Knra.Time.format(a.scanned_at)}<br />{a.lane.name}</div>
          <div class="min-w-0 text-muted">
            <div class="truncate">{a.goods_description || "—"}</div>
            <div class="truncate text-xs text-subtle">{a.importer_name}</div>
          </div>
          <div class="font-mono text-xs">{a.invoice && a.invoice.number}</div>
          <div><.invoice_badge invoice={a.invoice} /></div>
          <div><.stage_badge stage={a.stage} /></div>
        </.link>
        <.empty :if={@apps == []} text="No applications match." />
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Applications", filters: %{}) |> load()}
  end

  @impl true
  def handle_event("filter", %{"filter" => f}, socket) do
    {:noreply, socket |> assign(:filters, f) |> load()}
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    socket
    |> assign(:apps, Screening.list_applications(socket.assigns.filters))
    |> assign(:filter, to_form(socket.assigns.filters, as: :filter))
  end
end
