defmodule KnraWeb.InspectionsLive do
  @moduledoc "Field inspection officer's worklist (mobile-first)."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_applications}}

  alias Knra.Screening

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="inspections"
    >
      <div class="mx-auto max-w-xl">
        <.page_header title="My Inspections">
          <:subtitle>
            {@current_scope.user.station || "Divert bay"} · containers diverted by the CAS for secondary (handheld) inspection.
          </:subtitle>
        </.page_header>

        <div class="space-y-3">
          <.link
            :for={a <- @tasks}
            navigate={~p"/applications/#{a.reference}"}
            id={"task-#{a.reference}"}
            class="block rounded-md border border-line bg-white p-4 transition-colors hover:border-brand"
          >
            <div class="mb-1.5 flex items-center justify-between gap-2">
              <.container_no number={a.container_number} class="text-[15px]" />
              <.pill tone={:warn}>Secondary</.pill>
            </div>
            <div class="text-[13px] text-muted">{a.goods_description || "Goods not yet known"}</div>
            <div :if={a.adjudication} class="mt-1 text-xs text-subtle">
              Diverted {Knra.Time.format(a.adjudication.inserted_at)} · {a.adjudication.classification}
            </div>
            <div class="mt-1 text-xs text-subtle">
              {a.lane.name} · gamma {a.gamma_cps} cps · neutron {a.neutron_cps} cps
            </div>
          </.link>
          <div :if={@tasks == []} class="rounded-md border border-line bg-white">
            <.empty text="No inspections assigned." />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "My Inspections") |> load()}
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket), do: assign(socket, :tasks, Screening.list_by_stage("secondary"))
end
