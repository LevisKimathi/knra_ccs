defmodule KnraWeb.ApplicationLive.Show do
  @moduledoc """
  Screening application detail. Every role opens applications here; the action
  panel on the right shows only what the user's role may do at the current stage:
  CAS adjudication, field inspection, maker–checker report, payment recording.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :view_applications}}

  alias Knra.{Billing, Screening}
  alias Knra.Accounts.Policy
  alias Knra.Billing.{Invoice, Payment}
  alias Knra.Screening.{Adjudication, Application, Inspection}

  @gamma_threshold 100
  @neutron_threshold 5

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active={@active}
      wide
    >
      <.page_header
        title={Application.display_container(@app.container_number)}
        back={@back}
        back_label="Back"
      >
        <:subtitle>
          <span class="font-mono">{@app.reference}</span>
          · {@app.goods_description || "Goods not yet known"} · {@app.importer_name ||
            "Importer not yet known"}
        </:subtitle>
        <:actions>
          <.stage_badge stage={@app.stage} />
          <.link
            :if={@app.invoice}
            navigate={~p"/applications/#{@app.reference}/invoice"}
            class={btn(:secondary, :sm)}
          >
            <.icon name="hero-document-text" class="size-4" /> Invoice
          </.link>
          <.link
            :if={@app.certificate_number}
            navigate={~p"/applications/#{@app.reference}/certificate"}
            class={btn(:primary, :sm)}
          >
            <.icon name="hero-check-badge" class="size-4" /> Certificate
          </.link>
        </:actions>
      </.page_header>

      <.review_banner
        :if={@app.review_status}
        app={@app}
        can_review={Policy.can?(@current_scope, :review_flagged)}
      />

      <.banners app={@app} can_retry={Policy.can?(@current_scope, :retry_lookup)} />

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_400px]">
        <div class="min-w-0 space-y-5">
          <.card title="Detector Response">
            <:actions>
              <.pill tone={if(@app.alarmed, do: :bad, else: :ok)}>
                {if @app.alarmed, do: "ALARM", else: "NO ALARM"}
              </.pill>
            </:actions>
            <.channel
              :if={@app.gamma_cps}
              name="Gamma"
              value={@app.gamma_cps}
              threshold={gamma_threshold()}
              scale={300}
            />
            <.channel
              :if={@app.neutron_cps}
              name="Neutron"
              value={@app.neutron_cps}
              threshold={neutron_threshold()}
              scale={10}
            />
            <p :if={@app.gamma_cps || @app.neutron_cps} class="text-xs text-subtle">
              Vertical marker = alarm threshold. Counts over background.
            </p>
            <p
              :if={is_nil(@app.gamma_cps) and is_nil(@app.neutron_cps)}
              class="text-[13px] text-muted"
            >
              No RIID reading was recorded for this pass.
            </p>
            <div class="mt-5 border-t border-line-soft pt-5">
              <.kv
                cols={3}
                rows={[
                  {"Occupancy", @app.occupancy_ref},
                  {"Lane", "#{@app.lane.name} · #{@app.lane.device_code}"},
                  {"Scanned", Knra.Time.format(@app.scanned_at)},
                  {"Recorded by",
                   if(@app.source == "manual",
                     do: "RPM operator #{@app.recorded_by && @app.recorded_by.name}",
                     else: "RPM feed (OCR)"
                   )}
                ]}
              />
            </div>
            <div :if={@app.evidence_photos != []} class="mt-5 border-t border-line-soft pt-5">
              <div class="mb-2 text-[11px] font-bold uppercase tracking-[0.06em] text-subtle">
                Evidence photos
              </div>
              <div class="grid grid-cols-3 gap-2 sm:grid-cols-4">
                <a
                  :for={p <- @app.evidence_photos}
                  href={~p"/applications/#{@app.reference}/photos/#{p}"}
                  target="_blank"
                  class="block overflow-hidden rounded border border-line"
                >
                  <img
                    src={~p"/applications/#{@app.reference}/photos/#{p}"}
                    class="aspect-square w-full object-cover"
                  />
                </a>
              </div>
            </div>
          </.card>

          <.card title="Consignment">
            <:subtitle>from KenTrade TradeNet</:subtitle>
            <:actions>
              <.pill tone={lookup_tone(@app.lookup_status)}>{lookup_label(@app.lookup_status)}</.pill>
            </:actions>
            <.consignment app={@app} />
          </.card>

          <.payment_card
            app={@app}
            can_record={Policy.can?(@current_scope, :record_payment)}
            bank_form={@bank_form}
            show_bank={@show_bank}
          />
        </div>

        <%!-- Action panel first on handhelds (field officers), right-hand column on desktop --%>
        <div class="min-w-0 space-y-5 max-xl:order-first">
          <.card :if={@app.adjudication || @app.stage == "alarm"} title="CAS Adjudication">
            <%= cond do %>
              <% @app.adjudication -> %>
                <.decision
                  title={Adjudication.decision_label(@app.adjudication.decision)}
                  tone={decision_tone(@app.adjudication.decision)}
                  by={@app.adjudication.user.name}
                  at={@app.adjudication.inserted_at}
                  tag={@app.adjudication.classification}
                  text={@app.adjudication.reason}
                />
              <% Policy.can?(@current_scope, :adjudicate) -> %>
                <.adjudication_form form={@adj_form} user={@current_scope.user} />
              <% true -> %>
                <p class="text-[13px] text-muted">Awaiting adjudication by a CAS operator.</p>
            <% end %>
          </.card>

          <.card :if={@app.inspection || @app.stage == "secondary"} title="Secondary Inspection">
            <%= cond do %>
              <% @app.inspection -> %>
                <.decision
                  title={Inspection.outcome_label(@app.inspection.outcome)}
                  tone={if(@app.inspection.outcome == "detain", do: :bad, else: :ok)}
                  by={@app.inspection.user.name}
                  at={@app.inspection.inserted_at}
                  tag={"#{@app.inspection.isotope} · #{@app.inspection.dose_rate_usv_h} µSv/h at 1 m"}
                  text={@app.inspection.findings}
                />
                <div :if={@app.inspection.photos != []} class="mt-3 grid grid-cols-3 gap-2">
                  <a
                    :for={p <- @app.inspection.photos}
                    href={~p"/applications/#{@app.reference}/photos/#{p}"}
                    target="_blank"
                    class="block overflow-hidden rounded border border-line"
                  >
                    <img
                      src={~p"/applications/#{@app.reference}/photos/#{p}"}
                      class="aspect-square w-full object-cover"
                    />
                  </a>
                </div>
              <% Policy.can?(@current_scope, :inspect) -> %>
                <.inspection_form form={@insp_form} uploads={@uploads} app={@app} />
              <% true -> %>
                <p class="text-[13px] text-muted">
                  Awaiting the field inspection officer at the divert bay.
                </p>
            <% end %>
          </.card>

          <.card :if={@app.auto_approved} title="Screening Report" id="report">
            <p class="text-[13px] leading-relaxed text-muted">
              <strong class="text-ok">Approved automatically.</strong>
              The RPM pass showed no alarm and the system setting
              <em>Auto-clear passes with no alarm</em>
              was on, so no screening report or verification was required.
            </p>
          </.card>

          <.report_card
            :if={not @app.auto_approved}
            app={@app}
            scope={@current_scope}
            report_form={@report_form}
            reject_form={@reject_form}
          />

          <.card title="Status Timeline">
            <.timeline entries={@timeline} />
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  ## ------------------------------------------------------------------
  ## Sections

  attr :app, :map, required: true
  attr :can_review, :boolean, required: true

  defp review_banner(assigns) do
    ~H"""
    <div
      id="review-banner"
      class={[
        "mb-5 rounded-md border px-5 py-4 text-sm",
        if(@app.review_status == "pending",
          do: "border-warn/30 bg-warn-soft text-warn",
          else: "border-line bg-white text-muted"
        )
      ]}
    >
      <div class="font-bold">
        {if @app.review_status == "pending",
          do: "Flagged for review — recorded without KenTrade confirmation",
          else: "Recorded without KenTrade confirmation — reviewed"}
      </div>
      <div class="mt-1">
        Reason given by {(@app.recorded_by && @app.recorded_by.name) || "the RPM operator"}:
        <span class="text-ink">{@app.override_reason}</span>
      </div>
      <div :if={@app.review_status == "reviewed"} class="mt-1">
        Reviewed by {@app.reviewed_by && @app.reviewed_by.name} · {Knra.Time.format(@app.reviewed_at)}
        <span :if={@app.review_note}> —                {@app.review_note}</span>
      </div>
      <.form
        :if={@can_review and @app.review_status == "pending"}
        for={%{}}
        as={:review}
        id="review-form"
        phx-submit="mark_reviewed"
        class="mt-3 flex flex-wrap items-end gap-3"
      >
        <div class="min-w-64 flex-1">
          <.input name="review[note]" value="" label="Review note (optional)" />
        </div>
        <button type="submit" class={[btn(:ok, :sm), "mb-2"]} phx-disable-with="Saving…">
          Mark as Reviewed
        </button>
      </.form>
    </div>
    """
  end

  attr :app, :map, required: true
  attr :can_retry, :boolean, required: true

  defp banners(assigns) do
    ~H"""
    <div class="mb-5 space-y-3">
      <div
        :if={@app.stage == "detained"}
        class="rounded-md border border-bad/30 bg-bad-soft px-5 py-4 text-sm text-bad"
      >
        <strong>Detained.</strong>
        This container may not be released. The supervisor has been notified.
      </div>
      <div
        :if={@app.stage == "cleared"}
        class="rounded-md border border-ok/30 bg-ok-soft px-5 py-4 text-sm text-ok"
      >
        <strong>Cleared {Knra.Time.format(@app.cleared_at)}.</strong>
        Radiation screening certificate <span class="font-mono">{@app.certificate_number}</span>
        issued.
      </div>
      <div
        :if={@app.stage == "approved"}
        class="rounded-md border border-warn/30 bg-warn-soft px-5 py-4 text-sm text-warn"
      >
        <strong>
          {if @app.auto_approved,
            do: "Approved automatically (no alarm).",
            else: "Screening report approved."}
        </strong>
        Invoice <span class="font-mono">{@app.invoice.number}</span>
        is still pending — the certificate is issued as soon as it is paid.
      </div>
      <div
        :if={@app.lookup_status in ["not_found", "error", "transit"]}
        class="flex flex-wrap items-center gap-3 rounded-md border border-warn/30 bg-warn-soft px-5 py-4 text-sm text-warn"
      >
        <div class="min-w-0 flex-1">
          <strong>{lookup_label(@app.lookup_status)}.</strong> {@app.lookup_message}
        </div>
        <button :if={@can_retry} id="retry-lookup" phx-click="retry_lookup" class={btn(:warn, :sm)}>
          <.icon name="hero-arrow-path" class="size-4" /> Retry KenTrade lookup
        </button>
      </div>
      <div
        :if={@app.lookup_status == "pending"}
        class="rounded-md border border-line bg-white px-5 py-4 text-sm text-muted"
      >
        <.icon name="hero-arrow-path" class="size-4 motion-safe:animate-spin" />
        Querying KenTrade for the consignment…
      </div>
    </div>
    """
  end

  attr :app, :map, required: true

  defp consignment(assigns) do
    movement = get_in(assigns.app.consignment, ["movement"]) || %{}

    assigns =
      assigns
      |> assign(:movement, movement)
      |> assign(:vessel, movement["vesselCall"] || %{})
      |> assign(:container, movement["container"] || %{})
      |> assign(:consignments, List.wrap(movement["consignments"]))
      |> assign(:warnings, List.wrap(assigns.app.consignment["warnings"]))

    ~H"""
    <%= if @movement == %{} do %>
      <p class="text-[13px] text-muted">
        {if @app.lookup_status == "pending",
          do: "Waiting for KenTrade…",
          else: "No consignment particulars are available for this container."}
      </p>
    <% else %>
      <div
        :if={@warnings != []}
        class="mb-4 rounded border border-warn/30 bg-warn-soft px-4 py-3 text-xs text-warn"
      >
        <div :for={w <- @warnings}>{w}</div>
      </div>
      <.kv
        cols={3}
        rows={[
          {"Container",
           [
             Application.display_container(@app.container_number),
             @container["size"] &&
               "#{@container["size"]}'#{@container["type"] && " " <> @container["type"]}"
           ]
           |> Enum.reject(&is_nil/1)
           |> Enum.join(" · ")},
          {"Seal", @container["sealNumber"]},
          {"Gross weight",
           @container["grossWeightKg"] &&
             "#{Billing.fmt(@container["grossWeightKg"]) |> String.replace(".00", "")} kg"},
          {"Vessel / voyage",
           [@vessel["vesselNumber"], @vessel["voyageNumber"]]
           |> Enum.reject(&is_nil/1)
           |> Enum.join(" V.")},
          {"Manifest", @vessel["manifestNumber"]},
          {"Arrival", @vessel["estimatedArrival"] |> short_date()},
          {"Shipping agent", @vessel["shippingAgent"]},
          {"Port of discharge", @vessel["portOfDischarge"]},
          {"Transport mode", @movement["transportMode"]}
        ]}
      />
      <div :for={{c, i} <- Enum.with_index(@consignments)} class="mt-5 border-t border-line-soft pt-5">
        <div
          :if={length(@consignments) > 1}
          class="mb-3 text-xs font-bold uppercase tracking-wide text-muted"
        >
          Consignment {i + 1} of {length(@consignments)}
        </div>
        <.kv
          cols={3}
          rows={[
            {"Importer", get_in(c, ["importer", "name"])},
            {"Importer PIN", get_in(c, ["importer", "pin"])},
            {"Declaration", get_in(c, ["importer", "declarationNumber"])},
            {"Importer address", get_in(c, ["importer", "address"])},
            {"Consignor", get_in(c, ["consignor", "name"])},
            {"UCR", c["ucrNumber"]},
            {"Bill of lading", c["billOfLadingNumber"]},
            {"Port of loading", c["portOfLoading"]},
            {"Place of delivery", c["placeOfDelivery"]}
          ]}
        />
        <div class="mt-4 overflow-hidden rounded border border-line">
          <div class="grid grid-cols-[1fr_120px] gap-3 bg-panel px-4 py-2 text-[11px] font-bold uppercase tracking-wide text-muted">
            <div>Goods</div>
            <div>HS code</div>
          </div>
          <div
            :for={g <- List.wrap(c["goods"])}
            class="grid grid-cols-[1fr_120px] gap-3 border-t border-line-soft px-4 py-2 text-[13px]"
          >
            <div>
              {g["description"]}<span :if={g["unNumber"]} class="ml-2 text-xs text-bad">UN {g["unNumber"]}</span>
            </div>
            <div class="font-mono text-xs">{g["hsCode"]}</div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  attr :app, :map, required: true
  attr :can_record, :boolean, required: true
  attr :bank_form, :any, required: true
  attr :show_bank, :boolean, required: true

  defp payment_card(assigns) do
    ~H"""
    <.card :if={@app.invoice} title="Screening Fee" id="payment">
      <:actions><.invoice_badge invoice={@app.invoice} /></:actions>
      <.kv
        cols={3}
        rows={[
          {"Invoice", @app.invoice.number},
          {"Amount", "USD #{money(@app.invoice.amount_usd)} · KES #{money(@app.invoice.amount_kes)}"},
          {"Balance", "KES #{money(Invoice.balance(@app.invoice))}"}
        ]}
      />

      <div :if={@app.invoice.payments != []} class="mt-5 overflow-hidden rounded border border-line">
        <div
          :for={p <- @app.invoice.payments}
          class="flex flex-wrap items-center gap-3 border-b border-line-soft px-4 py-2.5 text-[13px] last:border-0"
        >
          <.icon name="hero-banknotes" class="size-4 text-ok" />
          <span class="font-semibold">{Payment.method_label(p.method)}</span>
          <span class="font-mono text-xs">{p.reference}</span>
          <span class="text-xs text-muted">{p.payer}</span>
          <span class="flex-1"></span>
          <span class="font-mono text-xs">KES {money(p.amount_kes)}</span>
          <span class="text-xs text-muted">{Knra.Time.format(p.received_at)}</span>
        </div>
      </div>

      <div
        :if={@app.invoice.status == "pending"}
        class="mt-5 rounded border border-line bg-panel px-4 py-3.5 text-[13px] leading-relaxed"
      >
        The importer pays outside the system: M-Pesa Paybill <strong>222222</strong>, account
        <strong class="font-mono">{@app.invoice.number}</strong>
        (matched automatically), or bank transfer quoting the invoice number (confirmed below).
      </div>

      <div :if={@can_record and @app.invoice.status == "pending"} class="mt-4">
        <button :if={!@show_bank} id="show-bank" phx-click="toggle_bank" class={btn(:outline, :sm)}>
          Record bank transfer
        </button>
        <.form
          :if={@show_bank}
          for={@bank_form}
          id="bank-form"
          phx-submit="record_bank"
          class="rounded border border-line p-4"
        >
          <div class="grid gap-x-4 sm:grid-cols-3">
            <.input field={@bank_form[:reference]} label="Bank reference" required />
            <.input
              field={@bank_form[:amount_kes]}
              type="number"
              step="0.01"
              label="Amount (KES)"
              required
            />
            <.input field={@bank_form[:payer]} label="Paid by" />
          </div>
          <div class="mt-2 flex gap-2">
            <button type="submit" class={btn(:ok, :sm)} phx-disable-with="Saving…">
              Confirm transfer received
            </button>
            <button type="button" phx-click="toggle_bank" class={btn(:secondary, :sm)}>Cancel</button>
          </div>
        </.form>
      </div>
    </.card>
    """
  end

  attr :form, :any, required: true
  attr :user, :map, required: true

  defp adjudication_form(assigns) do
    ~H"""
    <p class="mb-4 text-xs text-muted">
      Recorded against {@user.name}. A classification and reason are mandatory.
    </p>
    <.form for={@form} id="adjudication-form" phx-change="validate_adj" phx-submit="adjudicate">
      <.input
        field={@form[:classification]}
        type="select"
        label="Classification"
        prompt="Select classification"
        options={Adjudication.classifications()}
      />
      <.input
        field={@form[:reason]}
        type="textarea"
        label="Reason / note (required)"
        rows="4"
        placeholder="Basis for the decision"
      />
      <div class="mt-2 flex flex-col gap-2">
        <button
          type="submit"
          name="adjudication[decision]"
          value="release"
          class={btn(:ok)}
          phx-disable-with="Saving…"
        >
          Release occupancy — no objection
        </button>
        <button
          type="submit"
          name="adjudication[decision]"
          value="secondary"
          class={btn(:warn)}
          phx-disable-with="Saving…"
        >
          Divert to secondary inspection
        </button>
        <button
          type="submit"
          name="adjudication[decision]"
          value="detain"
          class={btn(:danger)}
          phx-disable-with="Saving…"
        >
          Detain &amp; escalate to supervisor
        </button>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :uploads, :any, required: true
  attr :app, :map, required: true

  defp inspection_form(assigns) do
    ~H"""
    <div
      :if={@app.adjudication}
      class="mb-4 rounded border border-warn/30 bg-warn-soft px-4 py-3 text-xs leading-relaxed text-warn"
    >
      <strong>CAS note</strong> — {@app.adjudication.reason}
    </div>
    <.form for={@form} id="inspection-form" phx-change="validate_insp" phx-submit="inspect">
      <.input
        field={@form[:isotope]}
        type="select"
        label="Handheld RIID reading"
        options={Inspection.isotopes()}
      />
      <.input
        field={@form[:dose_rate_usv_h]}
        type="number"
        step="0.001"
        label="Max dose rate at 1 m (µSv/h)"
      />
      <.input
        field={@form[:findings]}
        type="textarea"
        label="Findings (required)"
        rows="4"
        placeholder="What was inspected, where the source was located, condition of packaging"
      />

      <div class="mb-2 text-sm font-semibold">Photographs</div>
      <label
        for={@uploads.photos.ref}
        phx-drop-target={@uploads.photos.ref}
        class="mb-3 flex cursor-pointer flex-col items-center justify-center rounded border-2 border-dashed border-line px-4 py-5 text-center text-xs text-muted hover:border-brand"
      >
        <.icon name="hero-camera" class="mb-1 size-6" />
        Seal, container door and RIID screen — tap to take or choose photos (up to 6)
        <.live_file_input upload={@uploads.photos} class="sr-only" />
      </label>
      <div :if={@uploads.photos.entries != []} class="mb-3 grid grid-cols-3 gap-2">
        <div :for={entry <- @uploads.photos.entries} class="relative">
          <.live_img_preview
            entry={entry}
            class="aspect-square w-full rounded border border-line object-cover"
          />
          <button
            type="button"
            phx-click="cancel_photo"
            phx-value-ref={entry.ref}
            class="absolute top-1 right-1 rounded-full bg-white/90 p-0.5 text-bad"
            aria-label="Remove"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
          <div :for={err <- upload_errors(@uploads.photos, entry)} class="text-xs text-bad">
            {upload_error(err)}
          </div>
        </div>
      </div>
      <div :for={err <- upload_errors(@uploads.photos)} class="mb-2 text-xs text-bad">
        {upload_error(err)}
      </div>

      <div class="mt-2 flex flex-col gap-2">
        <button
          type="submit"
          name="inspection[outcome]"
          value="no_objection"
          class={btn(:ok)}
          phx-disable-with="Submitting…"
        >
          Inspection complete — no objection
        </button>
        <button
          type="submit"
          name="inspection[outcome]"
          value="detain"
          class={btn(:danger)}
          phx-disable-with="Submitting…"
        >
          Recommend detention
        </button>
      </div>
    </.form>
    """
  end

  attr :app, :map, required: true
  attr :scope, :map, required: true
  attr :report_form, :any, required: true
  attr :reject_form, :any, required: true

  defp report_card(assigns) do
    report = Application.current_report(assigns.app)
    last_rejected = Enum.find(assigns.app.reports, &(&1.status == "rejected"))

    assigns =
      assigns
      |> assign(:report, report)
      |> assign(
        :rejected,
        if(report && report.status == "rejected", do: report, else: nil) ||
          (assigns.app.stage == "report_draft" && last_rejected)
      )
      |> assign(
        :can_make,
        assigns.app.stage == "report_draft" and Policy.can?(assigns.scope, :draft_report)
      )
      |> assign(
        :can_check,
        assigns.app.stage == "report_check" and Policy.can?(assigns.scope, :verify_report)
      )
      |> assign(
        :own_report,
        report && report.status == "submitted" && report.maker_id == assigns.scope.user.id &&
          not Policy.segregation_exempt?(assigns.scope)
      )

    ~H"""
    <.card
      :if={@app.stage in ~w(report_draft report_check approved cleared)}
      title="Screening Report"
      id="report"
    >
      <.kv
        cols={2}
        rows={[
          {"Screening result",
           (@report && @report.status != "rejected" && @report.result) ||
             Screening.report_result(@app)},
          {"CAS adjudication",
           (@app.adjudication && @app.adjudication.classification) || "Not required"},
          {"Secondary inspection",
           (@app.inspection && "#{@app.inspection.isotope} · #{@app.inspection.dose_rate_usv_h} µSv/h") ||
             "Not required"},
          {"Recommendation", "Release — no radiological objection"}
        ]}
      />

      <div
        :if={@report && @report.status != "rejected"}
        class="mt-4 rounded border border-line bg-panel px-4 py-3 text-[13px] leading-relaxed"
      >
        <div class="mb-1 text-[11px] font-bold uppercase tracking-wide text-subtle">
          Checking officer's narrative
        </div>
        {@report.narrative}
      </div>

      <div class="mt-5 space-y-3">
        <div class="text-sm font-bold">Approval</div>
        <.approval_step
          title="Checking Officer"
          done={@report && @report.status != "rejected"}
          detail={
            (@report && @report.status != "rejected" &&
               "#{@report.maker.name} · #{Knra.Time.format(@report.submitted_at)}") ||
              "Not yet submitted"
          }
        />
        <.approval_step
          title="Verification Officer"
          done={@report && @report.status == "approved"}
          detail={
            cond do
              @report && @report.status == "approved" ->
                "#{@report.checker.name} · #{Knra.Time.format(@report.decided_at)}"

              @report && @report.status == "submitted" ->
                "Awaiting verification"

              true ->
                "Awaiting the checking officer"
            end
          }
        />
      </div>

      <div
        :if={@rejected}
        class="mt-4 rounded border border-bad/30 bg-bad-soft px-4 py-3 text-xs text-bad"
      >
        <strong>Returned by {@rejected.checker && @rejected.checker.name}:</strong> {@rejected.rejection_reason}
      </div>

      <.form
        :if={@can_make}
        for={@report_form}
        id="report-form"
        phx-change="validate_report"
        phx-submit="submit_report"
        class="mt-5"
      >
        <.input
          field={@report_form[:narrative]}
          type="textarea"
          label="Officer's narrative"
          rows="5"
          placeholder="Summary of the screening, adjudication and any secondary inspection"
        />
        <button type="submit" class={[btn(:primary), "w-full"]} phx-disable-with="Submitting…">
          Submit for verification
        </button>
      </.form>

      <div
        :if={@can_check and @own_report}
        class="mt-5 rounded border border-warn/30 bg-warn-soft px-4 py-3 text-xs text-warn"
      >
        Segregation of duties: you drafted this report, so another verification officer must approve it.
      </div>

      <div :if={@can_check and not @own_report} class="mt-5 space-y-3">
        <button
          id="approve-report"
          phx-click="approve_report"
          class={[btn(:ok), "w-full"]}
          phx-disable-with="Approving…"
          data-confirm={
            if @app.invoice && @app.invoice.status == "paid",
              do:
                "The screening fee is paid, so the container will be cleared and its certificate issued immediately.",
              else: "The certificate will be issued as soon as the screening fee is paid."
          }
          data-confirm-title="Approve Screening Report"
          data-confirm-button="Approve"
          data-confirm-variant="ok"
        >
          Approve screening report
        </button>
        <.form for={@reject_form} id="reject-form" phx-submit="reject_report">
          <.input
            field={@reject_form[:rejection_reason]}
            type="textarea"
            label="Reason (required to reject)"
            rows="3"
            placeholder="What must the checking officer correct?"
          />
          <button type="submit" class={[btn(:danger), "w-full"]} phx-disable-with="Returning…">
            Reject &amp; return to checking officer
          </button>
        </.form>
      </div>
    </.card>
    """
  end

  attr :title, :string, required: true
  attr :detail, :string, required: true
  attr :done, :any, required: true

  defp approval_step(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <span class={[
        "mt-1 size-2.5 flex-none rounded-full",
        if(@done, do: "bg-ok", else: "bg-[#c9d1d8]")
      ]}>
      </span>
      <div>
        <div class="text-[13px] font-semibold">{@title}</div>
        <div class="text-xs text-muted">{@detail}</div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :tone, :atom, required: true
  attr :by, :string, required: true
  attr :at, :any, required: true
  attr :tag, :string, required: true
  attr :text, :string, required: true

  defp decision(assigns) do
    ~H"""
    <div class={[
      "rounded border px-4 py-3.5",
      @tone == :ok && "border-ok/30 bg-ok-soft",
      @tone == :warn && "border-warn/30 bg-warn-soft",
      @tone == :bad && "border-bad/30 bg-bad-soft"
    ]}>
      <div class={[
        "text-sm font-bold",
        @tone == :ok && "text-ok",
        @tone == :warn && "text-warn",
        @tone == :bad && "text-bad"
      ]}>
        {@title}
      </div>
      <div class="mt-0.5 text-xs text-muted">{@by} · {Knra.Time.format(@at)}</div>
      <div class="mt-2 text-xs font-semibold">{@tag}</div>
      <div class="mt-1 text-[13px] leading-relaxed">{@text}</div>
    </div>
    """
  end

  ## ------------------------------------------------------------------
  ## Lifecycle

  @impl true
  def mount(%{"ref" => ref}, _session, socket) do
    {:ok,
     socket
     |> assign(:ref, ref)
     |> assign(:show_bank, false)
     |> assign(:adj_form, to_form(Screening.change_adjudication(), as: :adjudication))
     |> assign(
       :insp_form,
       to_form(Screening.change_inspection(%{"isotope" => "K-40 (NORM)"}), as: :inspection)
     )
     |> assign(:report_form, to_form(Screening.change_report(), as: :report))
     |> assign(:reject_form, to_form(Screening.change_rejection(), as: :rejection))
     |> allow_upload(:photos,
       accept: ~w(.jpg .jpeg .png .webp .heic),
       max_entries: 6,
       max_file_size: 10_000_000
     )
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Only known screens, never a caller-supplied path (open redirect)
    back = if params["from"] == "simulator", do: ~p"/simulator", else: back_path(socket)
    {:noreply, assign(socket, :back, back)}
  end

  defp load(socket) do
    app = Screening.get_application!(socket.assigns.ref)

    socket
    |> assign(:app, app)
    |> assign(:page_title, Application.display_container(app.container_number))
    |> assign(:timeline, Screening.timeline(app))
    |> assign(
      :active,
      socket.assigns.current_scope |> KnraWeb.Nav.back_for_application() |> elem(1)
    )
    |> assign_new(:bank_form, fn ->
      to_form(
        Billing.change_bank_payment(%{
          "amount_kes" => app.invoice && Invoice.balance(app.invoice)
        }),
        as: :payment
      )
    end)
  end

  defp back_path(socket),
    do: socket.assigns.current_scope |> KnraWeb.Nav.back_for_application() |> elem(0)

  @impl true
  def handle_info({:application, _, ref, _}, %{assigns: %{ref: ref}} = socket),
    do: {:noreply, load(socket)}

  def handle_info(_, socket), do: {:noreply, socket}

  ## ------------------------------------------------------------------
  ## Events

  @impl true
  def handle_event("validate_adj", %{"adjudication" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :adj_form,
       to_form(Screening.change_adjudication(params), as: :adjudication, action: :validate)
     )}
  end

  def handle_event("adjudicate", %{"adjudication" => params}, socket) do
    socket.assigns.current_scope
    |> Screening.adjudicate(socket.assigns.app, params)
    |> handle_result(socket, :adj_form, :adjudication, fn app ->
      case app.stage do
        "report_draft" -> "Occupancy released. Report drafting opened."
        "secondary" -> "Diverted to the divert bay. The field officer has been notified."
        "detained" -> "Container detained. Supervisor notified."
      end
    end)
  end

  def handle_event("validate_insp", %{"inspection" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :insp_form,
       to_form(Screening.change_inspection(params), as: :inspection, action: :validate)
     )}
  end

  def handle_event("cancel_photo", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :photos, ref)}
  end

  def handle_event("inspect", %{"inspection" => params}, socket) do
    changeset = Screening.change_inspection(params)

    if changeset.valid? do
      photos = store_photos(socket)

      socket.assigns.current_scope
      |> Screening.submit_inspection(socket.assigns.app, params, photos)
      |> handle_result(socket, :insp_form, :inspection, fn app ->
        if app.stage == "detained",
          do: "Detention recommended. Supervisor notified.",
          else: "Inspection submitted. Report drafting opened."
      end)
    else
      {:noreply,
       assign(socket, :insp_form, to_form(changeset, as: :inspection, action: :validate))}
    end
  end

  def handle_event("validate_report", %{"report" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :report_form,
       to_form(Screening.change_report(params), as: :report, action: :validate)
     )}
  end

  def handle_event("submit_report", %{"report" => params}, socket) do
    socket.assigns.current_scope
    |> Screening.submit_report(socket.assigns.app, params)
    |> handle_result(socket, :report_form, :report, fn _ ->
      "Submitted to the verification officer."
    end)
  end

  def handle_event("approve_report", _params, socket) do
    socket.assigns.current_scope
    |> Screening.approve_report(socket.assigns.app)
    |> handle_result(socket, nil, nil, fn app ->
      if app.stage == "cleared",
        do: "Approved. Invoice already paid — certificate #{app.certificate_number} issued.",
        else: "Approved. The certificate will be issued once the invoice is paid."
    end)
  end

  def handle_event("reject_report", %{"rejection" => params}, socket) do
    socket.assigns.current_scope
    |> Screening.reject_report(socket.assigns.app, params)
    |> handle_result(socket, :reject_form, :rejection, fn _ ->
      "Returned to the checking officer."
    end)
  end

  def handle_event("retry_lookup", _params, socket) do
    case Screening.retry_lookup(socket.assigns.current_scope, socket.assigns.app) do
      {:ok, app} ->
        {:noreply,
         socket |> put_flash(:info, "KenTrade: #{lookup_label(app.lookup_status)}.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Screening.error_message(reason))}
    end
  end

  def handle_event("mark_reviewed", %{"review" => %{"note" => note}}, socket) do
    case Screening.mark_reviewed(socket.assigns.current_scope, socket.assigns.app, note) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Marked as reviewed.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Screening.error_message(reason))}
    end
  end

  def handle_event("toggle_bank", _params, socket),
    do: {:noreply, update(socket, :show_bank, &(!&1))}

  def handle_event("record_bank", %{"payment" => params}, socket) do
    case Billing.record_bank_transfer(
           socket.assigns.current_scope,
           socket.assigns.app.invoice,
           params
         ) do
      {:ok, _payment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Bank transfer recorded.")
         |> assign(:show_bank, false)
         |> assign(:bank_form, to_form(Billing.change_bank_payment(), as: :payment))
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :bank_form, to_form(cs, as: :payment))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Screening.error_message(reason))}
    end
  end

  defp handle_result(result, socket, form_key, form_as, message_fun) do
    case result do
      {:ok, app} ->
        socket =
          if form_key,
            do:
              assign(
                socket,
                form_key,
                to_form(Ecto.Changeset.change(socket.assigns[form_key].source.data), as: form_as)
              ),
            else: socket

        {:noreply, socket |> put_flash(:info, message_fun.(app)) |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form_key, to_form(cs, as: form_as, action: :insert))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, Screening.error_message(reason)) |> load()}
    end
  end

  defp store_photos(socket) do
    dir =
      Path.join(Elixir.Application.fetch_env!(:knra, :uploads_dir), socket.assigns.app.reference)

    File.mkdir_p!(dir)

    consume_uploaded_entries(socket, :photos, fn %{path: path}, entry ->
      ext = entry.client_name |> Path.extname() |> String.downcase()
      name = "#{Ecto.UUID.generate()}#{ext}"
      File.cp!(path, Path.join(dir, name))
      {:ok, name}
    end)
  end

  ## ------------------------------------------------------------------
  ## Helpers

  defp gamma_threshold, do: @gamma_threshold
  defp neutron_threshold, do: @neutron_threshold

  defp decision_tone("release"), do: :ok
  defp decision_tone("secondary"), do: :warn
  defp decision_tone("detain"), do: :bad

  defp lookup_tone("found"), do: :ok
  defp lookup_tone("pending"), do: :neutral
  defp lookup_tone(_), do: :warn

  def lookup_label("found"), do: "Found"
  def lookup_label("pending"), do: "Looking up"
  def lookup_label("transit"), do: "Transit cargo"
  def lookup_label("not_found"), do: "No KenTrade record"
  def lookup_label("error"), do: "KenTrade lookup failed"

  defp short_date(nil), do: nil

  defp short_date(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Knra.Time.format(dt)
      _ -> iso
    end
  end

  defp upload_error(:too_large), do: "File is larger than 10 MB"
  defp upload_error(:too_many_files), do: "At most 6 photos"
  defp upload_error(:not_accepted), do: "Only JPG, PNG, WEBP or HEIC images"
  defp upload_error(e), do: to_string(e)
end
