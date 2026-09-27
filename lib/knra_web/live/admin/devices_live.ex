defmodule KnraWeb.Admin.DevicesLive do
  @moduledoc "RPM device inventory, calibration and in/out-of-service state (M8)."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :manage_devices}}

  alias Knra.Devices
  alias Knra.Devices.Lane

  @cols "90px 1fr 170px 150px 150px 220px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="devices"
    >
      <.page_header title="RPM devices">
        <:subtitle>
          Port of Mombasa. Taking a lane out of service reroutes traffic away from it; every state change
          is audited with its reason.
        </:subtitle>
        <:actions>
          <button id="add-lane" phx-click="edit" phx-value-id="new" class={btn(:primary, :sm)}>
            Register device
          </button>
        </:actions>
      </.page_header>

      <.card
        :if={@edit_form}
        title={if @editing == "new", do: "Register device", else: "Edit device"}
        class="mb-5"
      >
        <.form for={@edit_form} id="lane-form" phx-change="validate" phx-submit="save">
          <div class="grid gap-x-4 sm:grid-cols-3">
            <.input field={@edit_form[:name]} label="Lane" />
            <.input field={@edit_form[:device_code]} label="Device code" disabled={@editing != "new"} />
            <.input field={@edit_form[:serial_number]} label="Serial number" />
            <.input field={@edit_form[:detector_type]} label="Detector type" />
            <.input field={@edit_form[:terminal]} label="Terminal" />
            <.input field={@edit_form[:calibration_due_on]} type="date" label="Calibration due" />
          </div>
          <div class="flex gap-2">
            <button type="submit" class={btn(:primary, :sm)}>Save</button>
            <button type="button" phx-click="cancel" class={btn(:secondary, :sm)}>Cancel</button>
          </div>
        </.form>
      </.card>

      <.card padded={false}>
        <.thead cols={@cols}>
          <div>Lane</div>
          <div>Device / serial</div>
          <div>Type</div>
          <div>Calibration</div>
          <div>State</div>
          <div></div>
        </.thead>
        <div
          :for={lane <- @lanes}
          id={"device-#{lane.id}"}
          class="border-b border-line-soft last:border-0"
        >
          <div
            class="grid items-center gap-1 px-5 py-3 text-[13px] md:gap-3"
            style={"--cols: #{@cols}"}
          >
            <div class="font-semibold">{lane.name}</div>
            <div>
              <div class="font-mono text-xs">{lane.device_code}</div>
              <div class="text-xs text-muted">{lane.serial_number}</div>
            </div>
            <div class="text-muted">{lane.detector_type}</div>
            <div class={[
              Lane.calibration_overdue?(lane) && "font-semibold text-bad",
              Lane.calibration_due_soon?(lane) && "font-semibold text-warn"
            ]}>
              {Knra.Time.format_date(lane.calibration_due_on)}
              <div :if={Lane.calibration_overdue?(lane)} class="text-xs">Overdue</div>
              <div :if={Lane.calibration_due_soon?(lane)} class="text-xs">Due within 30 days</div>
            </div>
            <div>
              <.pill tone={if(lane.in_service, do: :ok, else: :warn)}>
                {if lane.in_service, do: "In service", else: "Out of service"}
              </.pill>
              <div :if={lane.status_reason} class="mt-1 text-xs text-muted">{lane.status_reason}</div>
            </div>
            <div class="flex justify-end gap-2">
              <button phx-click="edit" phx-value-id={lane.id} class={btn(:secondary, :sm)}>
                Edit
              </button>
              <button
                :if={lane.in_service}
                phx-click="ask_fault"
                phx-value-id={lane.id}
                class={btn(:warn, :sm)}
              >
                Mark faulty
              </button>
              <button
                :if={!lane.in_service}
                phx-click="return"
                phx-value-id={lane.id}
                class={btn(:ok, :sm)}
                data-confirm={"Return #{lane.name} to service?"}
              >
                Return to service
              </button>
            </div>
          </div>
          <.form
            :if={@fault_id == lane.id}
            for={%{}}
            as={:fault}
            id={"fault-form-#{lane.id}"}
            phx-submit="mark_fault"
            class="flex flex-wrap items-end gap-3 bg-warn-soft px-5 py-3"
          >
            <input type="hidden" name="fault[id]" value={lane.id} />
            <div class="min-w-64 flex-1">
              <.input
                name="fault[reason]"
                value=""
                label="Reason (required)"
                placeholder="e.g. Detector fault — gamma channel noisy"
              />
            </div>
            <button type="submit" class={[btn(:danger_solid, :sm), "mb-2"]}>
              Take out of service
            </button>
            <button type="button" phx-click="cancel" class={[btn(:secondary, :sm), "mb-2"]}>
              Cancel
            </button>
          </.form>
        </div>
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "RPM devices", fault_id: nil, edit_form: nil, editing: nil)
     |> load()}
  end

  @impl true
  def handle_info({:lane_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_event("edit", %{"id" => "new"}, socket) do
    {:noreply,
     assign(socket,
       editing: "new",
       fault_id: nil,
       edit_form: to_form(Devices.change_lane(%Lane{}))
     )}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    lane = Devices.get_lane!(id)

    {:noreply,
     assign(socket, editing: lane, fault_id: nil, edit_form: to_form(Devices.change_lane(lane)))}
  end

  def handle_event("validate", %{"lane" => params}, socket) do
    lane = if socket.assigns.editing == "new", do: %Lane{}, else: socket.assigns.editing

    {:noreply,
     assign(socket, :edit_form, to_form(Devices.change_lane(lane, params), action: :validate))}
  end

  def handle_event("save", %{"lane" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      if socket.assigns.editing == "new",
        do: Devices.create_lane(scope, params),
        else: Devices.update_lane(scope, socket.assigns.editing, params)

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Device saved.")
         |> assign(edit_form: nil, editing: nil)
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :edit_form, to_form(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  def handle_event("cancel", _, socket),
    do: {:noreply, assign(socket, fault_id: nil, edit_form: nil, editing: nil)}

  def handle_event("ask_fault", %{"id" => id}, socket) do
    {:noreply, assign(socket, fault_id: String.to_integer(id), edit_form: nil)}
  end

  def handle_event("mark_fault", %{"fault" => %{"id" => id, "reason" => reason}}, socket) do
    case Devices.mark_out_of_service(socket.assigns.current_scope, Devices.get_lane!(id), reason) do
      {:ok, lane} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{lane.name} taken out of service.")
         |> assign(:fault_id, nil)
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  def handle_event("return", %{"id" => id}, socket) do
    case Devices.return_to_service(socket.assigns.current_scope, Devices.get_lane!(id)) do
      {:ok, lane} ->
        {:noreply, socket |> put_flash(:info, "#{lane.name} returned to service.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  defp load(socket), do: assign(socket, :lanes, Devices.list_lanes())
end
