defmodule KnraWeb.Admin.PaymentsLive do
  @moduledoc "Payment reconciliation: M-Pesa payments that could not be matched to an invoice."
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :reconcile_payments}}

  alias Knra.Billing
  alias Knra.Billing.Payment

  @cols "130px 150px 160px 120px 1fr 330px"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :cols, @cols)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="payments"
    >
      <.page_header title="Payment Reconciliation">
        <:subtitle>
          M-Pesa Paybill payments are matched automatically when the account number is the invoice number.
          Payments whose account number did not match an invoice wait here to be applied manually.
        </:subtitle>
      </.page_header>

      <.card padded={false} title="Unmatched Payments">
        <.thead cols={@cols}>
          <div>Method</div>
          <div>Reference</div>
          <div>Account entered</div>
          <div>Amount</div>
          <div>Payer / received</div>
          <div>Apply to invoice</div>
        </.thead>
        <div
          :for={p <- @payments}
          id={"payment-#{p.id}"}
          class="grid items-center gap-1 border-b border-line-soft px-5 py-3 text-[13px] last:border-0 md:gap-3"
          style={"--cols: #{@cols}"}
        >
          <div>{Payment.method_label(p.method)}</div>
          <div class="font-mono text-xs">{p.reference}</div>
          <div class="font-mono text-xs text-bad">{p.account_reference || "—"}</div>
          <div class="font-mono text-xs">KES {money(p.amount_kes)}</div>
          <div class="text-xs text-muted">{p.payer}<br />{Knra.Time.format(p.received_at)}</div>
          <.form
            for={%{}}
            as={:match}
            id={"match-#{p.id}"}
            phx-submit="match"
            class="flex items-start gap-2"
          >
            <input type="hidden" name="match[id]" value={p.id} />
            <div class="flex-1">
              <.input name="match[invoice]" value="" placeholder="INV-2026-000123" />
            </div>
            <button type="submit" class={[btn(:primary, :sm), "mt-1"]}>Apply</button>
          </.form>
        </div>
        <.empty :if={@payments == []} text="All payments are reconciled." />
      </.card>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Payments") |> load()}
  end

  @impl true
  def handle_event("match", %{"match" => %{"id" => id, "invoice" => number}}, socket) do
    payment = Enum.find(socket.assigns.payments, &(to_string(&1.id) == id))

    case payment && Billing.reconcile_payment(socket.assigns.current_scope, payment, number) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Payment applied to #{String.upcase(number)}.") |> load()}

      {:error, :invoice_not_found} ->
        {:noreply, put_flash(socket, :error, "No invoice #{number} exists.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}

      nil ->
        {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket), do: assign(socket, :payments, Billing.list_unmatched_payments())
end
