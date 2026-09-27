defmodule KnraWeb.Admin.FeesLive do
  @moduledoc """
  Fee schedule (M9). Changes are proposed as a new version with an effective date
  and take effect only after a second supervisor approves them. Invoices keep the
  amounts of the schedule in force when they were raised.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :manage_fees}}

  alias Knra.Billing
  alias Knra.Billing.FeeSchedule

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} nav_counts={@nav_counts} active="fees">
      <.page_header title="Fee schedule">
        <:subtitle>
          Gazetted screening fees. Changes are versioned and need approval by a second supervisor before
          their effective date.
        </:subtitle>
        <:actions>
          <.link :if={@live_action == :index} patch={~p"/admin/fees/new"} class={btn(:primary, :sm)}>
            Propose change
          </.link>
        </:actions>
      </.page_header>

      <.card :if={@live_action == :new} title="Propose a new fee schedule" class="mb-6">
        <.form for={@form} id="fee-form" phx-change="validate" phx-submit="propose">
          <div class="grid gap-x-4 sm:grid-cols-[200px_1fr]">
            <.input field={@form[:effective_from]} type="date" label="Effective from" />
            <.input
              field={@form[:note]}
              label="Reason / gazette reference"
              placeholder="e.g. Gazette Notice No. 1234 of 2026"
            />
          </div>
          <div class="mb-2 grid grid-cols-[1fr_130px_130px] gap-3 text-[11px] font-bold uppercase tracking-wide text-muted">
            <div>Item</div>
            <div>USD</div>
            <div>KES</div>
          </div>
          <.inputs_for :let={item} field={@form[:items]}>
            <div class="grid grid-cols-[1fr_130px_130px] gap-3">
              <input type="hidden" name={item[:code].name} value={item[:code].value} />
              <input type="hidden" name={item[:position].name} value={item[:position].value} />
              <.input field={item[:description]} />
              <.input field={item[:amount_usd]} type="number" step="0.01" />
              <.input field={item[:amount_kes]} type="number" step="0.01" />
            </div>
          </.inputs_for>
          <div class="flex gap-2">
            <button type="submit" class={btn(:primary, :sm)} phx-disable-with="Submitting…">
              Submit for approval
            </button>
            <.link patch={~p"/admin/fees"} class={btn(:secondary, :sm)}>Cancel</.link>
          </div>
        </.form>
      </.card>

      <div class="space-y-5">
        <.card
          :for={s <- @schedules}
          id={"schedule-#{s.id}"}
          title={"Version #{s.version}"}
          padded={false}
        >
          <:subtitle>effective {Knra.Time.format_date(s.effective_from)}</:subtitle>
          <:actions>
            <.pill :if={@in_force && s.id == @in_force.id} tone={:ok}>In force</.pill>
            <.pill
              :if={
                s.status == "approved" and Date.compare(s.effective_from, Knra.Time.today()) == :gt
              }
              tone={:info}
            >
              Scheduled
            </.pill>
            <.pill :if={s.status == "pending_approval"} tone={:warn}>Pending approval</.pill>
            <.pill :if={s.status == "rejected"} tone={:bad}>Rejected</.pill>
            <.pill
              :if={
                s.status == "approved" and (!@in_force or s.id != @in_force.id) and
                  Date.compare(s.effective_from, Knra.Time.today()) != :gt
              }
              tone={:neutral}
            >
              Superseded
            </.pill>
          </:actions>
          <.thead cols="1fr 120px 120px">
            <div>Item</div>
            <div>Fee (USD)</div>
            <div>Fee (KES)</div>
          </.thead>
          <div
            :for={i <- s.items}
            class="grid gap-3 border-b border-line-soft px-5 py-2.5 text-[13px]"
            style="grid-template-columns: 1fr 120px 120px"
          >
            <div>{i.description}</div>
            <div class="font-mono">{money(i.amount_usd)}</div>
            <div class="font-mono">{money(i.amount_kes)}</div>
          </div>
          <div class="flex flex-wrap items-center gap-3 px-5 py-3 text-xs text-muted">
            <span>{s.note}</span>
            <span class="flex-1"></span>
            <span :if={s.created_by}>Proposed by {s.created_by.name}</span>
            <span :if={s.approved_by}>
              · {if s.status == "rejected", do: "Rejected", else: "Approved"} by {s.approved_by.name} {Knra.Time.format(
                s.approved_at
              )}
            </span>
          </div>
          <div :if={s.status == "rejected"} class="px-5 pb-3 text-xs text-bad">
            Reason: {s.rejection_reason}
          </div>
          <div
            :if={s.status == "pending_approval"}
            class="border-t border-line-soft bg-panel px-5 py-3"
          >
            <%= if s.created_by_id == @current_scope.user.id do %>
              <p class="text-xs text-warn">
                You proposed this change — another supervisor must approve it.
              </p>
            <% else %>
              <.form
                for={%{}}
                as={:decision}
                id={"decide-#{s.id}"}
                phx-submit="decide"
                class="flex flex-wrap items-end gap-3"
              >
                <input type="hidden" name="decision[id]" value={s.id} />
                <div class="min-w-64 flex-1">
                  <.input name="decision[reason]" value="" label="Reason (required to reject)" />
                </div>
                <button
                  type="submit"
                  name="decision[action]"
                  value="approve"
                  class={[btn(:ok, :sm), "mb-2"]}
                >
                  Approve
                </button>
                <button
                  type="submit"
                  name="decision[action]"
                  value="reject"
                  class={[btn(:danger, :sm), "mb-2"]}
                >
                  Reject
                </button>
              </.form>
            <% end %>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Fee schedule") |> load()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      if socket.assigns.live_action == :new do
        proposal = Billing.new_proposal()

        socket
        |> assign(:proposal, proposal)
        |> assign(:form, to_form(Billing.change_proposal(proposal)))
      else
        assign(socket, :form, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate", %{"fee_schedule" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :form,
       to_form(Billing.change_proposal(socket.assigns.proposal, params), action: :validate)
     )}
  end

  def handle_event("propose", %{"fee_schedule" => params}, socket) do
    case Billing.propose_fee_schedule(socket.assigns.current_scope, params) do
      {:ok, s} ->
        {:noreply,
         socket
         |> put_flash(:info, "Version #{s.version} submitted for approval.")
         |> push_patch(to: ~p"/admin/fees")
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :form, to_form(cs))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Knra.Screening.error_message(reason))}
    end
  end

  def handle_event("decide", %{"decision" => %{"id" => id, "action" => action} = d}, socket) do
    schedule = Billing.get_fee_schedule!(id)
    scope = socket.assigns.current_scope

    result =
      case action do
        "approve" -> Billing.approve_fee_schedule(scope, schedule)
        "reject" -> Billing.reject_fee_schedule(scope, schedule, d["reason"])
      end

    case result do
      {:ok, %FeeSchedule{} = s} ->
        {:noreply, socket |> put_flash(:info, "Version #{s.version} #{s.status}.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error(reason))}
    end
  end

  defp error(:segregation_of_duties), do: "You proposed this change, so you cannot decide it."

  defp error(:effective_date_passed),
    do: "The effective date has passed — propose a new version with a future date."

  defp error(:reason_required), do: "A reason is required to reject."
  defp error(other), do: Knra.Screening.error_message(other)

  defp load(socket) do
    assign(socket, schedules: Billing.list_fee_schedules(), in_force: Billing.schedule_in_force())
  end
end
