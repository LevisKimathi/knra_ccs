defmodule Knra.Screening do
  @moduledoc """
  The screening workflow (M3 CAS operations, M4 field inspection, M5 maker–checker,
  M7 certificate issuance).

      RPM pass ──► alarm ──adjudicate──► report_draft | secondary | detained
               └─(no alarm)──► report_draft
      secondary ──inspection──► report_draft | detained
      report_draft ──checking officer submits──► report_check
      report_check ──verification officer approves──► approved
                   └──rejects (reason)──► report_draft
      approved + invoice paid ──► cleared (certificate issued)

  Each transition locks the application row, checks the current stage and the
  caller's role, writes the change and its audit entry in one transaction, then
  broadcasts on PubSub so every open screen updates.
  """

  import Ecto.Query

  alias Knra.{Audit, Billing, Devices, Notifications, Repo}
  alias Knra.Accounts.Policy
  alias Knra.Integrations.KenTrade
  alias Knra.Screening.{Adjudication, Application, Inspection, Report}

  @topic "applications"
  @kentrade_actor "KenTrade TradeNet"

  def subscribe, do: Phoenix.PubSub.subscribe(Knra.PubSub, @topic)

  ## ------------------------------------------------------------------
  ## Queries

  @preloads [
    :lane,
    :adjudication,
    inspection: :user,
    invoice: :payments,
    reports: [:maker, :checker]
  ]

  def get_application!(reference) do
    Application
    |> Repo.get_by!(reference: reference)
    |> Repo.preload(@preloads ++ [adjudication: :user])
  end

  def get_application_by_certificate(number) do
    case Repo.get_by(Application,
           certificate_number: String.trim(number || "") |> String.upcase()
         ) do
      nil -> nil
      app -> Repo.preload(app, :lane)
    end
  end

  @doc "Applications list with optional `\"q\"` (container, reference, importer, invoice) and `\"stage\"` filters."
  def list_applications(filters \\ %{}, limit \\ 100) do
    Application
    |> join(:left, [a], i in assoc(a, :invoice), as: :invoice)
    |> filter_q(filters["q"])
    |> filter_stage(filters["stage"])
    |> order_by([a], desc: a.scanned_at)
    |> limit(^limit)
    |> preload([:lane, :invoice])
    |> Repo.all()
  end

  defp filter_q(q, s) when s in [nil, ""], do: q

  defp filter_q(q, s) do
    like = "%" <> String.replace(s, " ", "") <> "%"
    plain = "%" <> s <> "%"

    where(
      q,
      [a, invoice: i],
      ilike(a.container_number, ^like) or ilike(a.reference, ^plain) or
        ilike(a.importer_name, ^plain) or ilike(i.number, ^plain)
    )
  end

  defp filter_stage(q, s) when s in [nil, ""], do: q
  defp filter_stage(q, s), do: where(q, [a], a.stage == ^s)

  def list_by_stage(stage) do
    Repo.all(
      from a in Application,
        where: a.stage == ^stage,
        order_by: [asc: a.scanned_at],
        preload: [:lane, :adjudication, :invoice, reports: [:maker, :checker]]
    )
  end

  def recent_occupancies(limit \\ 8) do
    Repo.all(from a in Application, order_by: [desc: a.scanned_at], limit: ^limit, preload: :lane)
  end

  def stage_counts do
    Repo.all(from a in Application, group_by: a.stage, select: {a.stage, count(a.id)})
    |> Map.new()
  end

  @doc "Counts for today's lane-overview tiles (Nairobi day)."
  def today_stats do
    since = Knra.Time.start_of_day_utc(Knra.Time.today())

    Repo.one(
      from a in Application,
        where: a.scanned_at >= ^since,
        select: %{
          screened: count(a.id),
          alarms: filter(count(a.id), a.alarmed),
          cleared: filter(count(a.id), a.stage == "cleared"),
          detained: filter(count(a.id), a.stage == "detained")
        }
    )
  end

  def alarm_sla_minutes, do: Elixir.Application.get_env(:knra, :alarm_sla_minutes, 15)

  def timeline(%Application{reference: ref}), do: Audit.timeline(:application, ref)

  ## ------------------------------------------------------------------
  ## RPM occupancy (entry point)

  @doc """
  Ingests an RPM occupancy event: the OCR-read container number, lane device
  code, detector counts and alarm flag. Creates the screening application,
  raises the invoice, then looks the container up in KenTrade.

  Idempotent on `occupancy_ref`.
  """
  def ingest_occupancy(%{} = event) do
    container = KenTrade.normalise(event.container_number)

    with nil <- Repo.get_by(Application, occupancy_ref: event.occupancy_ref),
         :ok <- validate_container(container),
         {:ok, lane} <- fetch_lane(event.lane_code),
         :ok <- no_open_application(container) do
      scanned_at = event[:scanned_at] || Knra.Time.now()
      reference = Billing.next_number("application_number_seq", "CCS")
      lane_actor = lane.name

      Repo.transaction(fn ->
        app =
          Repo.insert!(%Application{
            reference: reference,
            container_number: container,
            stage: if(event.alarmed, do: "alarm", else: "report_draft"),
            lane_id: lane.id,
            occupancy_ref: event.occupancy_ref,
            scanned_at: scanned_at,
            gamma_cps: event.gamma_cps,
            neutron_cps: event.neutron_cps,
            alarmed: event.alarmed
          })

        disp = Application.display_container(container)

        Audit.log(
          lane_actor <> " · OCR camera",
          :application,
          reference,
          "Container #{disp} read by OCR on RPM pass",
          event.occupancy_ref
        )

        Audit.log(
          lane_actor,
          :application,
          reference,
          if(event.alarmed,
            do: "Radiation alarm — occupancy held for adjudication",
            else: "Occupancy recorded — no alarm"
          ),
          "Gamma #{event.gamma_cps} cps · neutron #{event.neutron_cps} cps"
        )

        Billing.raise_invoice!(app, scanned_at)
        app
      end)
      |> case do
        {:ok, app} ->
          app = Repo.preload(app, :lane)
          broadcast(app, :created)
          if app.alarmed, do: Notifications.alarm_raised(app)
          schedule_lookup(app)
          {:ok, app}

        error ->
          error
      end
    else
      %Application{} = existing -> {:ok, existing}
      error -> error
    end
  end

  defp validate_container(c) do
    if Regex.match?(~r/^[A-Z]{4}\d{7}$/, c), do: :ok, else: {:error, :invalid_container_number}
  end

  defp fetch_lane(code) do
    case Devices.get_lane_by_code(code) do
      nil -> {:error, :unknown_lane}
      %{in_service: false} -> {:error, :lane_out_of_service}
      lane -> {:ok, lane}
    end
  end

  # A second pass while a recent screening is still open is almost certainly the
  # same arrival, so it is refused. Containers are reused, so a detained or stale
  # (older than the status window) screening does not block a new arrival.
  defp no_open_application(container) do
    since =
      DateTime.add(Knra.Time.now(), -Knra.Screening.StatusQuery.window_days() * 86_400, :second)

    open =
      Repo.exists?(
        from a in Application,
          where:
            a.container_number == ^container and a.stage not in ["cleared", "detained"] and
              a.scanned_at >= ^since
      )

    if open, do: {:error, :already_in_screening}, else: :ok
  end

  defp schedule_lookup(app) do
    if Elixir.Application.get_env(:knra, :async_lookup, true) do
      Task.Supervisor.start_child(Knra.TaskSupervisor, fn -> lookup_consignment(app) end)
    else
      lookup_consignment(app)
    end
  end

  ## ------------------------------------------------------------------
  ## KenTrade consignment lookup (M2)

  @doc "Queries KenTrade for the container and stores the consignment particulars."
  def lookup_consignment(%Application{} = app) do
    app = Repo.preload(app, :lane)

    result =
      KenTrade.container_enquiry(app.container_number,
        reference_number: app.reference,
        location_code: app.lane && app.lane.device_code,
        event_datetime: app.scanned_at
      )

    {attrs, action, note} = lookup_attrs(result)

    Repo.transaction(fn ->
      updated =
        app
        |> Ecto.Changeset.change(Map.put(attrs, :lookup_at, Knra.Time.now()))
        |> Repo.update!()

      Audit.log(@kentrade_actor, :application, app.reference, action, note)
      updated
    end)
    |> tap(fn
      {:ok, updated} -> broadcast(updated, :updated)
      _ -> :ok
    end)
  end

  def retry_lookup(scope, %Application{} = app) do
    with :ok <- Policy.authorize(scope, :retry_lookup) do
      Audit.log(scope, :application, app.reference, "KenTrade lookup retried")
      lookup_consignment(app)
    end
  end

  defp lookup_attrs({:ok, %KenTrade.Result{status: "FOUND", movements: [movement | _]} = r}) do
    consignments = List.wrap(movement["consignments"])
    first = List.first(consignments) || %{}
    goods = Enum.flat_map(consignments, &List.wrap(&1["goods"]))

    importers =
      consignments
      |> Enum.map(&get_in(&1, ["importer", "name"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    importer =
      case importers do
        [one] -> one
        [] -> nil
        many -> "#{hd(many)} (+#{length(many) - 1} more)"
      end

    vessel = movement["vesselCall"] || %{}

    refs =
      [
        vessel["manifestNumber"]
        | Enum.flat_map(consignments, &[&1["billOfLadingNumber"], &1["ucrNumber"]])
      ]
      |> Enum.map(&Application.normalise_ref/1)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    attrs = %{
      lookup_status: "found",
      lookup_message: r.message,
      manifest_number: vessel["manifestNumber"],
      arrived_at: parse_datetime(vessel["estimatedArrival"]),
      consignment_refs: refs,
      consignment: %{
        "movement" => movement,
        "warnings" => r.warnings,
        "generated_at" => r.generated_at
      },
      importer_name: importer,
      goods_description:
        goods |> Enum.map(& &1["description"]) |> Enum.reject(&is_nil/1) |> Enum.join("; "),
      hs_code:
        goods
        |> Enum.map(& &1["hsCode"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.join(", "),
      ucr_number: first["ucrNumber"]
    }

    {attrs, "Consignment data retrieved — HS #{attrs.hs_code}, #{importer}",
     Enum.join(r.warnings, " ")}
  end

  defp lookup_attrs({:ok, %KenTrade.Result{status: "FOUND"} = r}) do
    {%{lookup_status: "not_found", lookup_message: r.message || "No movements returned"},
     "KenTrade returned no movement details", r.message}
  end

  defp lookup_attrs({:ok, %KenTrade.Result{status: "TRANSIT"} = r}) do
    {%{
       lookup_status: "transit",
       lookup_message: r.message,
       consignment: %{"warnings" => r.warnings}
     }, "Container is transit cargo — no consignment details", r.message}
  end

  defp lookup_attrs({:ok, %KenTrade.Result{status: "NOT_FOUND"} = r}) do
    {%{
       lookup_status: "not_found",
       lookup_message: r.message,
       consignment: %{"warnings" => r.warnings}
     }, "No KenTrade record for container", Enum.join([r.message | r.warnings], " ")}
  end

  defp lookup_attrs({:error, %KenTrade.Result{} = r}) do
    {%{lookup_status: "error", lookup_message: "#{r.status}: #{r.message}"},
     "KenTrade lookup failed", "#{r.status}: #{r.message}"}
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  ## ------------------------------------------------------------------
  ## CAS adjudication (M3)

  def change_adjudication(attrs \\ %{}), do: Adjudication.changeset(%Adjudication{}, attrs)

  @doc "Adjudicates an alarm: `decision` is release, secondary or detain; classification and reason are mandatory."
  def adjudicate(scope, %Application{} = app, attrs) do
    with :ok <- Policy.authorize(scope, :adjudicate) do
      transition(app, "alarm", fn app ->
        cs =
          %Adjudication{application_id: app.id, user_id: scope.user.id}
          |> Adjudication.changeset(attrs)

        with {:ok, adj} <- Repo.insert(cs) do
          next =
            %{"release" => "report_draft", "secondary" => "secondary", "detain" => "detained"}[
              adj.decision
            ]

          app = set_stage!(app, next)

          action =
            case adj.decision do
              "release" -> "Alarm adjudicated — released as #{adj.classification}"
              "secondary" -> "Diverted to secondary inspection (#{adj.classification})"
              "detain" -> "Container detained and escalated (#{adj.classification})"
            end

          Audit.log(scope, :application, app.reference, action, adj.reason)
          {:ok, app}
        end
      end)
      |> after_transition(fn app ->
        if app.stage == "detained", do: Notifications.detention(app, scope)
        if app.stage == "secondary", do: Notifications.secondary_assigned(app)
      end)
    end
  end

  ## ------------------------------------------------------------------
  ## Field inspection (M4)

  def change_inspection(attrs \\ %{}), do: Inspection.changeset(%Inspection{}, attrs)

  def submit_inspection(scope, %Application{} = app, attrs, photos \\ []) do
    with :ok <- Policy.authorize(scope, :inspect) do
      transition(app, "secondary", fn app ->
        cs =
          %Inspection{application_id: app.id, user_id: scope.user.id, photos: photos}
          |> Inspection.changeset(attrs)

        with {:ok, insp} <- Repo.insert(cs) do
          app =
            set_stage!(app, if(insp.outcome == "detain", do: "detained", else: "report_draft"))

          note = "#{insp.isotope} — max #{insp.dose_rate_usv_h} µSv/h at 1 m. #{insp.findings}"

          action =
            if insp.outcome == "detain",
              do: "Detention recommended after secondary inspection",
              else: "Secondary inspection completed — no objection"

          Audit.log(scope, :application, app.reference, action, note)
          {:ok, app}
        end
      end)
      |> after_transition(fn app ->
        if app.stage == "detained", do: Notifications.detention(app, scope)
      end)
    end
  end

  ## ------------------------------------------------------------------
  ## Maker–checker report (M5)

  def change_report(attrs \\ %{}), do: Report.narrative_changeset(%Report{}, attrs)
  def change_rejection(attrs \\ %{}), do: Report.rejection_changeset(%Report{}, attrs)

  @doc "Checking officer (maker) submits the screening report for verification."
  def submit_report(scope, %Application{} = app, attrs) do
    with :ok <- Policy.authorize(scope, :draft_report) do
      transition(app, "report_draft", fn app ->
        cs =
          %Report{
            application_id: app.id,
            maker_id: scope.user.id,
            submitted_at: Knra.Time.now(),
            status: "submitted",
            result: report_result(app)
          }
          |> Report.narrative_changeset(attrs)

        with {:ok, _report} <- Repo.insert(cs) do
          app = set_stage!(app, "report_check")

          Audit.log(
            scope,
            :application,
            app.reference,
            "Screening report submitted for verification"
          )

          {:ok, app}
        end
      end)
    end
  end

  @doc """
  Verification officer (checker) approves. Segregation of duties: the officer
  who drafted the report can never approve it.
  """
  def approve_report(scope, %Application{} = app) do
    with :ok <- Policy.authorize(scope, :verify_report) do
      transition(app, "report_check", fn app ->
        report = open_report!(app)

        if report.maker_id == scope.user.id do
          {:error, :segregation_of_duties}
        else
          report
          |> Ecto.Changeset.change(
            status: "approved",
            checker_id: scope.user.id,
            decided_at: Knra.Time.now()
          )
          |> Repo.update!()

          app = set_stage!(app, "approved")
          Audit.log(scope, :application, app.reference, "Screening report approved")
          {:ok, maybe_clear!(app)}
        end
      end)
      |> after_transition(&cleared_side_effects/1)
    end
  end

  @doc "Verification officer rejects and returns the report to the checking officer. A reason is required."
  def reject_report(scope, %Application{} = app, attrs) do
    with :ok <- Policy.authorize(scope, :verify_report) do
      transition(app, "report_check", fn app ->
        report = open_report!(app)

        cond do
          report.maker_id == scope.user.id ->
            {:error, :segregation_of_duties}

          true ->
            cs =
              report
              |> Report.rejection_changeset(attrs)
              |> Ecto.Changeset.change(
                status: "rejected",
                checker_id: scope.user.id,
                decided_at: Knra.Time.now()
              )

            with {:ok, report} <- Repo.update(cs) do
              app = set_stage!(app, "report_draft")

              Audit.log(
                scope,
                :application,
                app.reference,
                "Report rejected and returned to the checking officer",
                report.rejection_reason
              )

              {:ok, app}
            end
        end
      end)
    end
  end

  defp open_report!(app) do
    Repo.one!(
      from r in Report,
        where: r.application_id == ^app.id and r.status == "submitted",
        order_by: [desc: r.id],
        limit: 1
    )
  end

  def report_result(%Application{} = app) do
    app = Repo.preload(app, [:adjudication, :inspection])

    cond do
      not app.alarmed -> "No alarm — clear pass. No radiological objection."
      app.inspection -> "Alarm resolved at secondary inspection. No radiological objection."
      true -> "Alarm adjudicated at CAS. No radiological objection."
    end
  end

  ## ------------------------------------------------------------------
  ## Clearance (M7)

  @doc false
  # Called by Knra.Billing once an invoice is paid in full.
  # Takes the row lock so it cannot interleave with a concurrent approval.
  def invoice_paid(application_id) do
    Repo.transaction(fn ->
      app = Repo.one!(from a in Application, where: a.id == ^application_id, lock: "FOR UPDATE")
      maybe_clear!(app)
    end)
    |> after_transition(&cleared_side_effects/1)
  end

  # An approved application with a paid invoice is cleared and its certificate issued.
  defp maybe_clear!(%Application{stage: "approved"} = app) do
    invoice = Repo.get_by!(Knra.Billing.Invoice, application_id: app.id)

    if invoice.status == "paid" do
      number = certificate_number()

      app =
        app
        |> Ecto.Changeset.change(
          stage: "cleared",
          certificate_number: number,
          cleared_at: Knra.Time.now()
        )
        |> Repo.update!()

      Audit.log(
        "System",
        :application,
        app.reference,
        "Cleared — screening certificate #{number} issued"
      )

      app
    else
      Audit.log(
        "System",
        :application,
        app.reference,
        "Awaiting payment of #{invoice.number} before clearance"
      )

      app
    end
  end

  defp maybe_clear!(app), do: app

  defp cleared_side_effects(%Application{stage: "cleared"} = app), do: Notifications.cleared(app)
  defp cleared_side_effects(_), do: :ok

  defp certificate_number do
    %{rows: [[n]]} = Repo.query!("SELECT nextval('certificate_number_seq')")
    "KNRA/CCS/#{Knra.Time.year()}/#{n |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end

  ## ------------------------------------------------------------------
  ## Transition plumbing

  # Locks the row, checks the expected stage and runs `fun` in a transaction.
  defp transition(%Application{id: id}, expected_stage, fun) do
    Repo.transaction(fn ->
      app = Repo.one!(from a in Application, where: a.id == ^id, lock: "FOR UPDATE")

      if app.stage != expected_stage do
        Repo.rollback({:invalid_stage, app.stage})
      else
        case fun.(app) do
          {:ok, app} -> app
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end

  defp after_transition({:ok, app} = result, side_effects) do
    broadcast(app, :updated)
    side_effects.(app)
    result
  end

  defp after_transition(error, _), do: error

  defp set_stage!(app, stage), do: app |> Ecto.Changeset.change(stage: stage) |> Repo.update!()

  defp broadcast(%Application{} = app, event) do
    Phoenix.PubSub.broadcast(Knra.PubSub, @topic, {:application, event, app.reference, app.stage})
  end

  @doc "Human message for an error returned by this context."
  def error_message(:unauthorized), do: "Your role is not permitted to perform this action."

  def error_message(:segregation_of_duties),
    do: "Segregation of duties: you drafted this report, so you cannot verify it."

  def error_message({:invalid_stage, stage}),
    do:
      "This application has moved on (now: #{Application.stage_label(stage)}). Refresh and try again."

  def error_message(:invalid_container_number),
    do: "Container number must be 4 letters followed by 7 digits (ISO 6346)."

  def error_message(:unknown_lane), do: "Unknown RPM lane."
  def error_message(:lane_out_of_service), do: "That RPM lane is out of service."

  def error_message(:already_in_screening),
    do: "This container already has an open screening application."

  def error_message(:reason_required), do: "A reason is required."
  def error_message(other), do: "Action failed: #{inspect(other)}"
end
