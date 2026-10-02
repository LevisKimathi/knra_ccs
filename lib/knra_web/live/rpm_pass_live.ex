defmodule KnraWeb.RpmPassLive do
  @moduledoc """
  RPM operator's page. The CAS system does not capture container numbers, so the
  operator enters the number, looks it up in KenTrade, and records the pass
  (no alarm, or alarm held for CAS adjudication) with an optional RIID reading
  and evidence photos. From there the normal screening workflow continues.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :record_rpm_pass}}

  alias Knra.{Devices, Screening}
  alias Knra.Integrations.KenTrade
  alias Knra.Screening.Application

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="rpm_pass"
    >
      <div class="mx-auto max-w-2xl">
        <.page_header title="Record RPM Pass">
          <:subtitle>
            Enter the container number, check it against KenTrade, then record what the RPM showed.
          </:subtitle>
        </.page_header>

        <.card title="Container" class="mb-5">
          <.form for={@lookup_form} id="lookup-form" phx-change="edit_container" phx-submit="lookup">
            <div class="flex items-start gap-2">
              <div class="flex-1">
                <.input
                  field={@lookup_form[:container_number]}
                  placeholder="e.g. MSKU3990962"
                  autocomplete="off"
                  autocapitalize="characters"
                  spellcheck="false"
                  class="w-full input font-mono text-lg uppercase tracking-wide placeholder:font-sans placeholder:normal-case placeholder:tracking-normal"
                  phx-mounted={JS.focus()}
                />
              </div>
              <button
                type="submit"
                id="lookup-button"
                class={[btn(:primary), "mt-1"]}
                disabled={@looking_up}
              >
                <.icon :if={!@looking_up} name="hero-magnifying-glass" class="size-4" />
                <.icon
                  :if={@looking_up}
                  name="hero-arrow-path"
                  class="size-4 motion-safe:animate-spin"
                />
                {if @looking_up, do: "Looking Up…", else: "Look Up"}
              </button>
            </div>
          </.form>

          <.lookup_result :if={@lookup} lookup={@lookup} />

          <div
            :if={Screening.overridable?(@lookup) and not @override}
            class="mt-3 flex flex-wrap items-center gap-3 text-sm"
          >
            <span class="text-muted">The container is physically here and must be recorded?</span>
            <button type="button" id="record-anyway" phx-click="override" class={btn(:warn, :sm)}>
              Record Anyway
            </button>
          </div>
        </.card>

        <.card
          :if={found?(@lookup) or @override}
          title={if @override, do: "Record Pass Without KenTrade Confirmation", else: "Record Pass"}
          class="mb-5"
          id="record-card"
        >
          <.form for={@pass_form} id="pass-form" phx-change="validate" phx-submit="record">
            <input
              type="hidden"
              name="pass[container_number]"
              value={@pass_form[:container_number].value}
            />

            <div
              :if={@override}
              class="mb-4 rounded border border-warn/30 bg-warn-soft px-4 py-3 text-xs leading-relaxed text-warn"
            >
              <strong>This pass will be flagged for supervisor review.</strong>
              KenTrade could not confirm {Application.display_container(@looked_up)}, so it is recorded without
              consignment details. The details can be fetched later from the application page.
            </div>

            <.input
              :if={@override}
              field={@pass_form[:override_reason]}
              type="textarea"
              rows="3"
              label="Reason for recording without KenTrade confirmation (required)"
              placeholder="e.g. Container discharged from MV … this morning; KenTrade unavailable since 09:00"
            />

            <.input
              field={@pass_form[:lane_id]}
              type="select"
              label="RPM lane"
              prompt="Select the lane"
              options={Enum.map(@lanes, &{"#{&1.name} · #{&1.device_code}", &1.id})}
            />

            <fieldset class="mb-4">
              <legend class="mb-2 text-sm font-semibold">Result</legend>
              <div class="grid gap-2 sm:grid-cols-2">
                <label
                  :for={{value, title, detail, tone} <- outcomes()}
                  class={[
                    "flex cursor-pointer items-start gap-3 rounded border-2 px-4 py-3 transition-colors",
                    if(to_string(@pass_form[:outcome].value) == value,
                      do: if(tone == :ok, do: "border-ok bg-ok-soft", else: "border-bad bg-bad-soft"),
                      else: "border-line bg-white hover:border-subtle"
                    )
                  ]}
                >
                  <input
                    type="radio"
                    name="pass[outcome]"
                    value={value}
                    checked={to_string(@pass_form[:outcome].value) == value}
                    class="mt-1"
                    id={"outcome-#{value}"}
                  />
                  <span>
                    <span class={[
                      "block text-sm font-bold",
                      if(tone == :ok, do: "text-ok", else: "text-bad")
                    ]}>
                      {title}
                    </span>
                    <span class="block text-xs text-muted">{detail}</span>
                  </span>
                </label>
              </div>
              <p :if={@pass_form.errors[:outcome]} class="mt-1.5 text-sm text-error">
                Select a result
              </p>
            </fieldset>

            <div class="mb-1 text-sm font-semibold">
              RIID reading <span class="font-normal text-muted">(optional)</span>
            </div>
            <p class="mb-2 text-xs text-muted">Only if you took a reading with a handheld RIID.</p>
            <div class="grid grid-cols-2 gap-x-3">
              <.input field={@pass_form[:gamma_cps]} type="number" min="0" label="Gamma (cps)" />
              <.input field={@pass_form[:neutron_cps]} type="number" min="0" label="Neutron (cps)" />
            </div>

            <div class="mb-2 text-sm font-semibold">
              Evidence photos <span class="font-normal text-muted">(optional)</span>
            </div>
            <label
              for={@uploads.evidence.ref}
              phx-drop-target={@uploads.evidence.ref}
              class="mb-3 flex cursor-pointer flex-col items-center justify-center rounded border-2 border-dashed border-line px-4 py-5 text-center text-xs text-muted hover:border-brand"
            >
              <.icon name="hero-camera" class="mb-1 size-6" />
              Container, seal, RPM or RIID screen — tap to take or choose photos (up to 6)
              <.live_file_input upload={@uploads.evidence} class="sr-only" />
            </label>
            <div :if={@uploads.evidence.entries != []} class="mb-3 grid grid-cols-3 gap-2">
              <div :for={entry <- @uploads.evidence.entries} class="relative">
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
                <div :for={err <- upload_errors(@uploads.evidence, entry)} class="text-xs text-bad">
                  {upload_error(err)}
                </div>
              </div>
            </div>
            <div :for={err <- upload_errors(@uploads.evidence)} class="mb-2 text-xs text-bad">
              {upload_error(err)}
            </div>

            <button
              type="submit"
              id="record-button"
              class={[
                btn(if(@pass_form[:outcome].value == "alarm", do: :danger_solid, else: :ok)),
                "mt-2 w-full"
              ]}
              phx-disable-with="Recording…"
              data-confirm={confirm_message(@pass_form, @looked_up, @override)}
              data-confirm-title="Record RPM Pass"
              data-confirm-button="Record"
              data-confirm-variant={
                if(@pass_form[:outcome].value == "alarm", do: "danger", else: "ok")
              }
            >
              Record Pass
            </button>
          </.form>
        </.card>

        <.card title="My Recent Passes" padded={false}>
          <.link
            :for={a <- @recent}
            navigate={~p"/applications/#{a.reference}"}
            id={"recent-#{a.reference}"}
            class="flex items-center gap-3 border-b border-line-soft px-5 py-3 last:border-0 hover:bg-panel"
          >
            <span class={["size-2 flex-none rounded-full", if(a.alarmed, do: "bg-bad", else: "bg-ok")]}>
            </span>
            <div class="min-w-0 flex-1">
              <.container_no number={a.container_number} class="text-[13px]" />
              <div class="text-xs text-muted">
                {a.lane.name} · {Knra.Time.format(a.scanned_at)} · {a.reference}
              </div>
            </div>
            <.stage_badge stage={a.stage} />
          </.link>
          <.empty :if={@recent == []} text="Passes you record appear here." />
        </.card>
      </div>
    </Layouts.app>
    """
  end

  attr :lookup, :any, required: true

  defp lookup_result(%{lookup: {:ok, %KenTrade.Result{status: "FOUND"} = r}} = assigns) do
    movement = List.first(r.movements) || %{}
    vessel = movement["vesselCall"] || %{}
    consignments = List.wrap(movement["consignments"])
    first = List.first(consignments) || %{}
    goods = consignments |> Enum.flat_map(&List.wrap(&1["goods"]))

    assigns =
      assign(assigns,
        number: r.container_number,
        rows: [
          {"Vessel / voyage",
           [vessel["vesselNumber"], vessel["voyageNumber"]]
           |> Enum.reject(&is_nil/1)
           |> Enum.join(" V.")},
          {"Manifest", vessel["manifestNumber"]},
          {"Bill of lading",
           consignments
           |> Enum.map(& &1["billOfLadingNumber"])
           |> Enum.reject(&is_nil/1)
           |> Enum.join(", ")},
          {"Importer", get_in(first, ["importer", "name"])},
          {"Goods",
           goods
           |> Enum.map(& &1["description"])
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> Enum.join("; ")},
          {"HS code",
           goods
           |> Enum.map(& &1["hsCode"])
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> Enum.join(", ")}
        ],
        warnings: r.warnings
      )

    ~H"""
    <div id="lookup-result" class="mt-4 rounded border border-ok/30 bg-ok-soft px-4 py-3.5">
      <div class="mb-3 flex items-center gap-2 text-sm font-bold text-ok">
        <.icon name="hero-check-circle" class="size-5" /> Found in KenTrade ·
        <span class="font-mono">{Application.display_container(@number)}</span>
      </div>
      <.kv cols={2} rows={@rows} />
      <div :for={w <- @warnings} class="mt-2 text-xs text-warn">{w}</div>
    </div>
    """
  end

  defp lookup_result(assigns) do
    assigns = assign(assigns, :problem, problem(assigns.lookup))

    ~H"""
    <div
      id="lookup-result"
      class="mt-4 rounded border border-warn/30 bg-warn-soft px-4 py-3.5 text-sm text-warn"
    >
      <div class="font-bold">{elem(@problem, 0)}</div>
      <div class="mt-1">{elem(@problem, 1)}</div>
    </div>
    """
  end

  defp problem({:ok, %KenTrade.Result{status: "TRANSIT", message: m}}),
    do:
      {"Transit cargo",
       m || "KenTrade knows this container only as transit cargo; it cannot be recorded here."}

  defp problem({:ok, %KenTrade.Result{status: "NOT_FOUND"} = r}),
    do:
      {"No KenTrade record",
       Enum.join(
         [
           r.message || "KenTrade has no record of this container.",
           "Check the number and look it up again." | r.warnings
         ],
         " "
       )}

  defp problem({:error, %KenTrade.Result{status: s, message: m}}),
    do: {"KenTrade lookup failed (#{s})", (m || "") <> " Try again in a moment."}

  defp problem({:error, :invalid_container_number}),
    do: {"Invalid container number", "Enter 4 letters followed by 7 digits, e.g. MSKU3990962."}

  defp problem({:error, reason}), do: {"Lookup failed", Screening.error_message(reason)}

  defp found?({:ok, %KenTrade.Result{status: "FOUND"}}), do: true
  defp found?(_), do: false

  defp outcomes do
    [
      {"pass", "Pass — no alarm", "Goes straight to the screening report.", :ok},
      {"alarm", "Fail — radiation alarm", "Held in the alarm queue for CAS adjudication.", :bad}
    ]
  end

  defp confirm_message(form, looked_up, override) do
    number = if looked_up, do: Application.display_container(looked_up), else: "this container"

    base =
      case form[:outcome].value do
        "alarm" -> "Record a radiation alarm for #{number}? It will be held for CAS adjudication."
        "pass" -> "Record a clear pass (no alarm) for #{number}?"
        _ -> "Record this RPM pass for #{number}?"
      end

    if override,
      do: base <> " It is not confirmed by KenTrade and will be flagged for supervisor review.",
      else: base
  end

  ## ------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Record RPM Pass",
       looking_up: false,
       lookup: nil,
       looked_up: nil,
       override: false,
       lane_id: nil
     )
     |> assign(:lookup_form, to_form(%{"container_number" => ""}, as: :lookup))
     |> assign(:pass_form, to_form(Screening.change_manual_pass(), as: :pass))
     |> allow_upload(:evidence,
       accept: ~w(.jpg .jpeg .png .webp .heic),
       max_entries: 6,
       max_file_size: 10_000_000
     )
     |> load()}
  end

  @impl true
  def handle_event("edit_container", %{"lookup" => %{"container_number" => n}}, socket) do
    # A different number invalidates the previous lookup
    socket = assign(socket, :lookup_form, to_form(%{"container_number" => n}, as: :lookup))

    socket =
      if socket.assigns.looked_up && KenTrade.normalise(n) == socket.assigns.looked_up,
        do: socket,
        else: assign(socket, lookup: nil, looked_up: nil, override: false)

    {:noreply, socket}
  end

  def handle_event("lookup", %{"lookup" => %{"container_number" => n}}, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(looking_up: true, lookup: nil, looked_up: KenTrade.normalise(n), override: false)
     |> start_async(:lookup, fn -> Screening.lookup_for_manual_pass(scope, n) end)}
  end

  def handle_event("override", _params, socket) do
    params = %{
      "container_number" => socket.assigns.looked_up,
      "lane_id" => socket.assigns.lane_id
    }

    {:noreply,
     assign(socket,
       override: Screening.overridable?(socket.assigns.lookup),
       pass_form: to_form(Screening.change_manual_pass(params), as: :pass)
     )}
  end

  def handle_event("validate", %{"pass" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :pass_form,
       to_form(Screening.change_manual_pass(params), as: :pass, action: :validate)
     )}
  end

  def handle_event("cancel_photo", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :evidence, ref)}

  def handle_event("record", %{"pass" => params}, socket) do
    scope = socket.assigns.current_scope

    case Screening.record_manual_pass(
           scope,
           params,
           socket.assigns.lookup,
           socket.assigns.looked_up
         ) do
      {:ok, app} ->
        photos = store_photos(socket, app)
        {:ok, _} = Screening.attach_evidence(scope, app, photos)

        where =
          if app.alarmed, do: "sent to the alarm queue", else: "sent for the screening report"

        where =
          if app.review_status == "pending",
            do: where <> ". It is flagged for supervisor review",
            else: where

        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{Application.display_container(app.container_number)} recorded as #{app.reference} and #{where}."
         )
         |> assign(lookup: nil, looked_up: nil, override: false, lane_id: params["lane_id"])
         |> assign(:lookup_form, to_form(%{"container_number" => ""}, as: :lookup))
         |> assign(
           :pass_form,
           to_form(Screening.change_manual_pass(%{"lane_id" => params["lane_id"]}), as: :pass)
         )
         |> load()}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :pass_form, to_form(cs, as: :pass, action: :insert))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Screening.error_message(reason))}
    end
  end

  @impl true
  def handle_async(:lookup, {:ok, result}, socket) do
    socket = assign(socket, looking_up: false, lookup: result)

    socket =
      case result do
        {:ok, %KenTrade.Result{status: "FOUND", container_number: c}} ->
          params = %{"container_number" => c, "lane_id" => socket.assigns.lane_id}
          assign(socket, :pass_form, to_form(Screening.change_manual_pass(params), as: :pass))

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_async(:lookup, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       looking_up: false,
       lookup:
         {:error, %KenTrade.Result{status: "ERROR", message: "The lookup did not complete."}}
     )}
  end

  @impl true
  def handle_info({:lane_updated, _}, socket), do: {:noreply, load(socket)}
  def handle_info({:application, _, _, _}, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    assign(socket,
      lanes: Devices.list_in_service_lanes(),
      recent: Screening.list_manual_passes(socket.assigns.current_scope)
    )
  end

  defp store_photos(socket, app) do
    dir = Path.join(Elixir.Application.fetch_env!(:knra, :uploads_dir), app.reference)
    File.mkdir_p!(dir)

    consume_uploaded_entries(socket, :evidence, fn %{path: path}, entry ->
      name =
        "rpm-#{Ecto.UUID.generate()}#{entry.client_name |> Path.extname() |> String.downcase()}"

      File.cp!(path, Path.join(dir, name))
      {:ok, name}
    end)
  end

  defp upload_error(:too_large), do: "File is larger than 10 MB"
  defp upload_error(:too_many_files), do: "At most 6 photos"
  defp upload_error(:not_accepted), do: "Only JPG, PNG, WEBP or HEIC images"
  defp upload_error(e), do: to_string(e)
end
