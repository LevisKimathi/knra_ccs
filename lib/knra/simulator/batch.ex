defmodule Knra.Simulator.Batch do
  @moduledoc """
  Stages many containers at chosen screening statuses in one go, e.g. for a
  partner (KenTrade) testing the container status API.

  Each container gets a simulated RPM pass and is then walked through the real
  workflow (adjudication, inspection, report, verification, M-Pesa payment) up
  to its target stage, so the audit trail, invoice and certificate are the same
  as for a container processed by hand. Every step runs as the calling user,
  which therefore needs every workflow permission (a super admin).

  The request is free text, one container per line or separated by commas or
  spaces, each optionally followed by the status the API should answer:

      MRKU9937602 CLEARED
      INBU5333934=DETAINED
      MRKU2415627: IN_PROGRESS
      MSKU2728942 NOT_FOUND
      PONU8264392

  `IN_PROGRESS` leaves the screening awaiting its report; a workflow stage
  (`alarm`, `secondary`, `report_check`, `awaiting_payment`, …) can be given
  instead to hold it at a specific step. `NOT_FOUND` makes sure the container
  has no screening in the status window (one that already exists is reported,
  never deleted).

  Containers without a status are spread across CLEARED, DETAINED,
  IN_PROGRESS and NOT_FOUND in turn (or given `:default`). A container listed
  twice keeps its last status.
  """

  import Ecto.Query

  alias Knra.{Repo, Screening, Simulator}
  alias Knra.Accounts.Policy
  alias Knra.Billing.Invoice
  alias Knra.Integrations.KenTrade
  alias Knra.Screening.{Application, StatusQuery}

  # The status API answers, in the order used when spreading containers that
  # have no status. IN_PROGRESS is held at report_draft.
  @spread ~w(cleared detained report_draft not_found)

  @aliases %{
    "alarm" => "alarm",
    "alarm_adjudication" => "alarm",
    "secondary" => "secondary",
    "secondary_inspection" => "secondary",
    "inspection" => "secondary",
    "report_draft" => "report_draft",
    "report_pending" => "report_draft",
    "draft" => "report_draft",
    "in_progress" => "report_draft",
    "report_check" => "report_check",
    "verification_pending" => "report_check",
    "verification" => "report_check",
    "approved" => "approved",
    "awaiting_payment" => "approved",
    "unpaid" => "approved",
    "cleared" => "cleared",
    "detained" => "detained",
    "not_found" => "not_found"
  }

  @permissions ~w(simulate adjudicate inspect draft_report verify_report)a

  def spread_order, do: @spread

  @doc "What the status API answers for a target, e.g. `IN_PROGRESS · Awaiting verification`."
  def target_label("cleared"), do: "CLEARED"
  def target_label("detained"), do: "DETAINED"
  def target_label("not_found"), do: "NOT_FOUND"
  def target_label(stage), do: "IN_PROGRESS · " <> Application.stage_label(stage)

  @doc "Accepted status words (stage names, API statuses/stages and a few synonyms)."
  def status_words, do: Map.keys(@aliases) |> Enum.sort()

  @doc """
  Parses the free-text request into `[{container, stage | nil}]` and a list of
  tokens that were neither a container number nor a status.
  """
  def parse(text) when is_binary(text) do
    tokens =
      text
      # "MSKU 774-1293" (as displayed) is one container, not three tokens
      |> String.replace(~r/\b([A-Za-z]{4})[ \t-]+(\d{3})[ \t-]?(\d{4})\b/, "\\1\\2\\3")
      |> String.split(~r/[\s,;=:|]+/, trim: true)
      |> Enum.reject(&(&1 in ["-", "->", "=>"]))

    {entries, bad} =
      Enum.reduce(tokens, {[], []}, fn token, {entries, bad} ->
        container = KenTrade.normalise(token)

        cond do
          Regex.match?(~r/^[A-Z]{4}\d{7}$/, container) ->
            {[{container, nil} | entries], bad}

          stage = stage_for(token) ->
            case entries do
              [{c, nil} | rest] -> {[{c, stage} | rest], bad}
              _ -> {entries, [token | bad]}
            end

          true ->
            {entries, [token | bad]}
        end
      end)

    # Last status wins for a repeated container; first-seen order is kept.
    entries = Enum.reverse(entries)
    last = Map.new(entries)

    {entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.map(&{&1, last[&1]}),
     Enum.reverse(bad)}
  end

  defp stage_for(token) do
    Map.get(@aliases, token |> String.downcase() |> String.replace("-", "_"))
  end

  @doc """
  Stages every container in `text`. Options: `:default` — stage for containers
  given without one (default: spread across all stages); `:lane` — lane device
  code (default `"auto"`).

  Returns `{:ok, results}` with one map per container
  (`container`, `target`, `result`, `api`), or `{:error, reason}`.
  """
  def run(scope, text, opts \\ []) do
    with :ok <- check(scope),
         {:ok, entries} <- entries(text, opts[:default]) do
      lane = opts[:lane] || "auto"

      results =
        Enum.map(entries, fn {container, target} ->
          %{container: container, target: target, result: stage(scope, container, target, lane)}
        end)

      api =
        results
        |> Enum.map(&%{"containerNumber" => &1.container})
        |> StatusQuery.lookup()

      {:ok, Enum.zip_with(results, api, &Map.put(&1, :api, &2))}
    end
  end

  defp check(scope) do
    cond do
      not Simulator.enabled?() -> {:error, :simulators_disabled}
      not Enum.all?(@permissions, &Policy.can?(scope, &1)) -> {:error, :needs_super_admin}
      true -> :ok
    end
  end

  defp entries(text, default) do
    case parse(text) do
      {[], []} ->
        {:error, :no_containers}

      {_, [_ | _] = bad} ->
        {:error, {:unrecognised, bad}}

      {entries, []} ->
        default = if default in [nil, "", "spread"], do: nil, else: stage_for(default)

        {:ok,
         entries
         |> Enum.with_index()
         |> Enum.map(fn {{c, stage}, i} ->
           {c, stage || default || Enum.at(@spread, rem(i, length(@spread)))}
         end)}
    end
  end

  @doc """
  Brings one container to `target`: continues its open screening if the target
  is still reachable from where it stands, otherwise starts a new RPM pass.
  A container whose latest screening is already at `target` is left alone.
  """
  def stage(scope, container, target, lane \\ "auto", opts \\ [])

  def stage(_scope, container, "not_found", _lane, _opts) do
    case latest(container) do
      nil -> :not_screened
      %Application{stage: stage} -> {:error, {:already_screened, stage}}
    end
  end

  def stage(scope, container, target, lane, opts) do
    case latest(container) do
      %Application{stage: ^target} = app ->
        {:unchanged, app}

      %Application{stage: stage} = app when stage not in ["cleared", "detained"] ->
        if reachable?(stage, target),
          do: advance(scope, app, target),
          else: {:error, {:open_at, stage}}

      _ ->
        # With "Auto-clear passes with no alarm" on, a clear pass skips the report
        # stages, so those are reached through an alarm that CAS then releases.
        alarm? =
          target in ["alarm", "secondary", "detained"] or
            (target in ["report_draft", "report_check"] and
               Knra.Settings.enabled?("auto_clear_no_alarm"))

        with {:ok, app} <- Simulator.rpm_pass(scope, container, lane, alarm?, opts) do
          advance(scope, app, target)
        end
    end
  end

  defp latest(container) do
    since = DateTime.add(Knra.Time.now(), -StatusQuery.window_days() * 86_400, :second)

    Repo.one(
      from a in Application,
        where: a.container_number == ^container and a.scanned_at >= ^since,
        order_by: [desc: a.scanned_at, desc: a.id],
        limit: 1
    )
  end

  @rank %{
    "alarm" => 0,
    "secondary" => 1,
    "report_draft" => 2,
    "report_check" => 3,
    "approved" => 4,
    "cleared" => 5
  }

  defp reachable?(from, "detained"), do: from in ["alarm", "secondary"]
  defp reachable?(from, "secondary"), do: from == "alarm"
  defp reachable?(from, t), do: @rank[t] > @rank[from]

  defp advance(_scope, %Application{stage: stage} = app, stage), do: {:ok, app}
  # A zero screening fee means the invoice is paid at once, so approval clears.
  defp advance(_scope, %Application{stage: "cleared"} = app, "approved"), do: {:ok, app}

  defp advance(scope, %Application{} = app, target) do
    case step(scope, app, target) do
      {:ok, _} -> advance(scope, Repo.get!(Application, app.id), target)
      {:error, reason} -> {:error, {:failed_at, app.stage, reason}}
    end
  end

  defp step(scope, %{stage: "alarm"} = app, target) do
    {decision, classification, reason} =
      case target do
        "secondary" ->
          {"secondary", "Unresolved — requires secondary",
           "Simulated: gamma above threshold, isotope unresolved at CAS."}

        "detained" ->
          {"detain", "Suspected threat material",
           "Simulated: spectrum consistent with an undeclared industrial source."}

        _ ->
          {"release", "NORM (naturally occurring)",
           "Simulated: NORM profile consistent with the declared goods."}
      end

    Screening.adjudicate(scope, app, %{
      "decision" => decision,
      "classification" => classification,
      "reason" => reason
    })
  end

  defp step(scope, %{stage: "secondary"} = app, target) do
    {outcome, isotope, dose, findings} =
      if target == "detained",
        do: {"detain", "Cs-137", "12.5", "Simulated: localised Cs-137 source found in cargo."},
        else:
          {"no_objection", "K-40 (NORM)", "0.35",
           "Simulated: NORM in ceramic goods, dose rate within limits."}

    Screening.submit_inspection(scope, app, %{
      "outcome" => outcome,
      "isotope" => isotope,
      "dose_rate_usv_h" => dose,
      "findings" => findings
    })
  end

  defp step(scope, %{stage: "report_draft"} = app, _target) do
    Screening.submit_report(scope, app, %{
      "narrative" => "Simulated screening for partner testing. No radiological objection."
    })
  end

  defp step(scope, %{stage: "report_check"} = app, _target),
    do: Screening.approve_report(scope, app)

  defp step(scope, %{stage: "approved"} = app, "cleared") do
    invoice = Repo.get_by!(Invoice, application_id: app.id)
    Simulator.mpesa_payment(scope, invoice.number, invoice.amount_kes, "254712345678")
  end

  defp step(_scope, app, target), do: {:error, {:unreachable, app.stage, target}}

  ## ------------------------------------------------------------------
  ## Containers the status API answered NOT_FOUND

  @doc """
  Containers that API clients asked about in the last `days` and got
  `NOT_FOUND`, and that still have no screening now. Read from the status API
  call log, which keeps each container's answer (the audit trail entry for a
  call only has the counts).

  Returns `{containers, invalid}`: `containers` is a list of maps (`container`,
  `asked`, `first_asked`, `last_asked`, `clients`), most recently asked first;
  `invalid` lists numbers that are not valid container numbers.
  """
  def unanswered(days \\ 7) do
    since = DateTime.add(Knra.Time.now(), -days * 86_400, :second)

    asked =
      Repo.all(
        from l in Knra.Integrations.Log,
          where:
            l.system in ["status_api", "kentrade_inbound"] and l.outcome == "ok" and
              l.inserted_at >= ^since,
          select: {l.inserted_at, l.request, l.response}
      )
      |> Enum.flat_map(fn {at, request, response} ->
        for %{"status" => "NOT_FOUND", "containerNumber" => c} <- List.wrap(response["items"]),
            is_binary(c),
            do: {KenTrade.normalise(c), at, request["client"]}
      end)
      |> Enum.group_by(&elem(&1, 0))

    {valid, invalid} =
      Enum.split_with(Map.keys(asked), &Regex.match?(~r/^[A-Z]{4}\d{7}$/, &1))

    still_unanswered =
      valid
      |> Enum.map(&%{"containerNumber" => &1})
      |> StatusQuery.lookup()
      |> Enum.filter(&(&1["status"] == "NOT_FOUND"))
      |> MapSet.new(& &1["containerNumber"])

    containers =
      valid
      |> Enum.filter(&MapSet.member?(still_unanswered, &1))
      |> Enum.map(fn c ->
        times = Enum.map(asked[c], &elem(&1, 1))

        %{
          container: c,
          asked: length(times),
          first_asked: Enum.min(times, DateTime),
          last_asked: Enum.max(times, DateTime),
          clients: asked[c] |> Enum.map(&elem(&1, 2)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        }
      end)
      |> Enum.sort_by(& &1.last_asked, {:desc, DateTime})

    {containers, Enum.sort(invalid)}
  end

  @doc """
  Looks each container up in KenTrade, records a simulated RPM pass carrying that
  KenTrade result (so its consignment details are stored at once), and walks it
  through the real workflow to CLEARED. Same rules as `run/3`: simulators
  enabled and a super admin. Returns `{:ok, results}` with `container`,
  `kentrade` (the TFP status), `result` and `api` (what the status API answers now).
  """
  def clear_unanswered(scope, containers, opts \\ []) do
    lane = opts[:lane] || "auto"

    with :ok <- check(scope) do
      results =
        Enum.map(containers, fn container ->
          lookup =
            KenTrade.container_enquiry(container,
              reference_number: "STATUS-QUERY-BACKFILL",
              event_datetime: Knra.Time.now()
            )

          kentrade =
            case lookup do
              {_, %KenTrade.Result{status: status}} -> status
              _ -> "ERROR"
            end

          %{
            container: container,
            target: "cleared",
            kentrade: kentrade,
            result: stage(scope, container, "cleared", lane, lookup: lookup)
          }
        end)

      api =
        results
        |> Enum.map(&%{"containerNumber" => &1.container})
        |> StatusQuery.lookup()

      {:ok, Enum.zip_with(results, api, &Map.put(&1, :api, &2))}
    end
  end

  @doc "Plain-text summary of results, for the console."
  def format(results) do
    Enum.map_join(results, "\n", fn r ->
      outcome =
        case r.result do
          {:ok, app} -> "#{app.reference}  #{app.stage}"
          {:unchanged, app} -> "#{app.reference}  #{app.stage} (already there)"
          :not_screened -> "no screening"
          {:error, reason} -> "FAILED: #{error_message(reason)}"
        end

      api = r.api["status"] <> if(r.api["stage"], do: "/#{r.api["stage"]}", else: "")

      String.pad_trailing(r.container, 13) <>
        String.pad_trailing(r.target |> target_label() |> String.replace(" · ", "/"), 44) <>
        String.pad_trailing(api, 34) <> outcome
    end)
  end

  def error_message(:simulators_disabled), do: "Simulators are disabled in this environment."

  def error_message(:needs_super_admin),
    do: "Staging drives every workflow step, so it must be run by a super admin."

  def error_message(:no_containers), do: "No container numbers found."

  def error_message({:unrecognised, bad}),
    do:
      "Not a container number or status: #{Enum.join(bad, ", ")}. " <>
        "Statuses: CLEARED, DETAINED, IN_PROGRESS, NOT_FOUND (or a stage such as AWAITING_PAYMENT)."

  def error_message({:open_at, stage}),
    do:
      "Already in screening at “#{Application.stage_label(stage)}”, which cannot move to that status."

  def error_message({:already_screened, stage}),
    do:
      "Already has a screening (#{Application.stage_label(stage)}), so the API cannot answer NOT_FOUND. " <>
        "Use a container number with no recent screening."

  def error_message({:failed_at, stage, reason}),
    do: "Stopped at “#{Application.stage_label(stage)}”: #{error_message(reason)}"

  def error_message({:unreachable, from, to}), do: "No path from #{from} to #{to}."
  def error_message(%Ecto.Changeset{errors: errors}), do: inspect(errors)
  def error_message(other), do: Screening.error_message(other)
end
