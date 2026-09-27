defmodule KnraWeb.SimulatorLive do
  @moduledoc """
  Sandbox panel standing in for the RPM hardware feed and M-Pesa Paybill
  confirmations. Drives the same code paths as the real integrations.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :simulate}}
  on_mount {KnraWeb.LiveHooks, :simulator}

  import Ecto.Query
  alias Knra.{Devices, Repo, Screening, Simulator}
  alias Knra.Billing.Invoice

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="simulator"
    >
      <.page_header title="RPM & M-Pesa simulator">
        <:subtitle>
          Stands in for hardware and payment callbacks in development and training environments.
          An RPM pass creates a real screening application, queries KenTrade and raises an invoice.
        </:subtitle>
      </.page_header>

      <div class="grid gap-5 lg:grid-cols-2">
        <.card title="Simulate RPM pass">
          <.form for={@rpm_form} id="rpm-form" phx-submit="rpm_pass">
            <.input
              field={@rpm_form[:container]}
              label="Container number (as read by OCR)"
              placeholder="e.g. OOLU4471228"
              list="sample-containers"
              autocomplete="off"
            />
            <datalist id="sample-containers">
              <option :for={c <- Simulator.sample_containers()} value={c}></option>
            </datalist>
            <.input
              field={@rpm_form[:lane]}
              type="select"
              label="Lane"
              options={[
                {"Auto-route to an in-service lane", "auto"}
                | Enum.map(@lanes, &{"#{&1.name} · #{&1.device_code}", &1.device_code})
              ]}
            />
            <.input field={@rpm_form[:alarm]} type="checkbox" label="Force radiation alarm" />
            <button type="submit" class={btn(:primary)} phx-disable-with="Scanning…">
              Send occupancy
            </button>
          </.form>
          <div class="mt-5 rounded border border-line bg-panel px-4 py-3 text-xs leading-relaxed text-muted">
            <div class="mb-1 font-semibold text-ink">KenTrade mock containers</div>
            Known (FOUND): {Enum.join(Map.keys(Knra.Integrations.KenTrade.MockPlug.catalogue()), ", ")}.<br />
            Transit: {Enum.join(Knra.Integrations.KenTrade.MockPlug.transit_containers(), ", ")}.<br />
            Any other valid number returns NOT_FOUND; ERRU0000000 returns a server error.
          </div>
        </.card>

        <.card title="Simulate M-Pesa Paybill payment" padded={false}>
          <div class="px-5 pt-4 text-xs text-muted">
            Paybill 222222. The account number the importer types is matched to the invoice number.
          </div>
          <div
            :for={inv <- @pending}
            id={"pending-#{inv.id}"}
            class="flex items-center gap-3 border-b border-line-soft px-5 py-3 text-[13px] last:border-0"
          >
            <div class="min-w-0 flex-1">
              <div class="font-mono text-xs">{inv.number}</div>
              <div class="text-xs text-muted">
                <.container_no number={inv.application.container_number} />
                · {Knra.Screening.Application.stage_label(inv.application.stage)}
              </div>
            </div>
            <span class="font-mono text-xs">KES {money(inv.amount_kes)}</span>
            <button phx-click="pay" phx-value-number={inv.number} class={btn(:ok, :sm)}>Pay</button>
          </div>
          <.empty :if={@pending == []} text="No pending invoices." />
          <.form
            for={@pay_form}
            id="pay-form"
            phx-submit="pay_custom"
            class="border-t border-line bg-panel px-5 py-4"
          >
            <div class="mb-2 text-xs font-semibold">
              Custom payment (e.g. mistyped account number or part-payment)
            </div>
            <div class="grid gap-x-3 sm:grid-cols-3">
              <.input field={@pay_form[:account]} placeholder="Account no." />
              <.input field={@pay_form[:amount]} type="number" placeholder="Amount KES" />
              <.input field={@pay_form[:msisdn]} placeholder="2547XXXXXXXX" />
            </div>
            <button type="submit" class={btn(:secondary, :sm)}>Send confirmation</button>
          </.form>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Simulator")
     |> assign(
       :rpm_form,
       to_form(%{"container" => "", "lane" => "auto", "alarm" => "false"}, as: :rpm)
     )
     |> assign(
       :pay_form,
       to_form(%{"account" => "", "amount" => "2600", "msisdn" => "254712345678"}, as: :pay)
     )
     |> load()}
  end

  @impl true
  def handle_event("rpm_pass", %{"rpm" => p}, socket) do
    case Simulator.rpm_pass(
           socket.assigns.current_scope,
           p["container"],
           p["lane"],
           p["alarm"] == "true"
         ) do
      {:ok, app} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{app.reference}: #{if app.alarmed, do: "radiation alarm — sent to the alarm queue", else: "clear pass — sent for report drafting"}."
         )
         |> push_navigate(to: ~p"/applications/#{app.reference}?from=/simulator")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, Screening.error_message(reason))
         |> assign(:rpm_form, to_form(p, as: :rpm))}
    end
  end

  def handle_event("pay", %{"number" => number}, socket) do
    inv = Enum.find(socket.assigns.pending, &(&1.number == number))
    pay(socket, number, inv.amount_kes, "254712345678")
  end

  def handle_event("pay_custom", %{"pay" => p}, socket) do
    pay(socket, p["account"], p["amount"], p["msisdn"])
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:lane_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp pay(socket, account, amount, msisdn) do
    case Simulator.mpesa_payment(socket.assigns.current_scope, account, amount, msisdn) do
      {:ok, %{status: "matched", reference: ref}} ->
        {:noreply,
         socket |> put_flash(:info, "M-Pesa #{ref} received and matched to #{account}.") |> load()}

      {:ok, %{status: "unmatched", reference: ref}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "M-Pesa #{ref} received but account #{account} matches no invoice — sent to reconciliation."
         )
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Payment rejected: #{inspect(cs.errors)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Screening.error_message(reason))}
    end
  end

  defp load(socket) do
    pending =
      Repo.all(
        from i in Invoice,
          where: i.status == "pending",
          order_by: [desc: i.id],
          limit: 12,
          preload: :application
      )

    assign(socket, lanes: Devices.list_in_service_lanes(), pending: pending)
  end
end
