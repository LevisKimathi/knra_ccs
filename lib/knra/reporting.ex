defmodule Knra.Reporting do
  @moduledoc """
  Management reports (M12): the Screening Summary and the Events Report.

  Every report covers RPM passes scanned in a period of Nairobi calendar dates
  (`from`..`to`, inclusive), optionally for one lane. Statuses are as they stand
  now; counts such as "active alarms" are therefore live.
  """

  import Ecto.Query

  alias Knra.{Audit, Repo}
  alias Knra.Billing.{Invoice, Payment}
  alias Knra.Devices.Lane
  alias Knra.Screening.{Adjudication, Application, Inspection, Report}

  @gamma_threshold 100
  @neutron_threshold 5

  @doc "Normalises filter params into `%{from: Date, to: Date, lane_id: id | nil}`."
  def filters(params \\ %{}) do
    today = Knra.Time.today()
    to = parse_date(params["to"]) || today
    from = parse_date(params["from"]) || Date.add(to, -29)
    {from, to} = if Date.compare(from, to) == :gt, do: {to, from}, else: {from, to}

    lane_id =
      case Integer.parse(to_string(params["lane_id"] || "")) do
        {id, ""} -> id
        _ -> nil
      end

    %{from: from, to: to, lane_id: lane_id}
  end

  defp parse_date(nil), do: nil

  defp parse_date(s) do
    case Date.from_iso8601(to_string(s)) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  def to_params(f) do
    %{"from" => Date.to_iso8601(f.from), "to" => Date.to_iso8601(f.to)}
    |> then(&if(f.lane_id, do: Map.put(&1, "lane_id", f.lane_id), else: &1))
  end

  defp bounds(f),
    do: {Knra.Time.start_of_day_utc(f.from), Knra.Time.start_of_day_utc(Date.add(f.to, 1))}

  # Applications scanned in the period (and lane)
  defp in_period(f) do
    {start, stop} = bounds(f)

    q = from a in Application, as: :app, where: a.scanned_at >= ^start and a.scanned_at < ^stop

    if f.lane_id, do: where(q, [a], a.lane_id == ^f.lane_id), else: q
  end

  defp lanes(f) do
    q = from l in Lane, order_by: l.name
    q = if f.lane_id, do: where(q, [l], l.id == ^f.lane_id), else: q
    Repo.all(q)
  end

  ## ------------------------------------------------------------------
  ## Screening Summary

  def screening_summary(f) do
    apps = in_period(f)

    totals =
      Repo.one(
        from a in apps,
          select: %{
            screened: count(a.id),
            alarms: filter(count(a.id), a.alarmed),
            cleared: filter(count(a.id), a.stage == "cleared"),
            detained: filter(count(a.id), a.stage == "detained"),
            in_progress: filter(count(a.id), a.stage not in ["cleared", "detained"]),
            auto_approved: filter(count(a.id), a.auto_approved),
            manual: filter(count(a.id), a.source == "manual"),
            flagged: filter(count(a.id), not is_nil(a.review_status))
          }
      )

    secondary =
      Repo.one(
        from a in apps,
          join: adj in Adjudication,
          on: adj.application_id == a.id,
          where: adj.decision == "secondary",
          select: count(a.id)
      )

    stages =
      Repo.all(from a in apps, group_by: a.stage, select: {a.stage, count(a.id)}) |> Map.new()

    by_lane =
      Repo.all(
        from a in apps,
          group_by: a.lane_id,
          select:
            {a.lane_id,
             %{
               screened: count(a.id),
               alarms: filter(count(a.id), a.alarmed),
               cleared: filter(count(a.id), a.stage == "cleared"),
               detained: filter(count(a.id), a.stage == "detained"),
               in_progress: filter(count(a.id), a.stage not in ["cleared", "detained"])
             }}
      )
      |> Map.new()

    daily =
      Repo.all(
        from a in apps,
          group_by: fragment("date(? + interval '3 hours')", a.scanned_at),
          order_by: fragment("date(? + interval '3 hours')", a.scanned_at),
          select:
            {fragment("date(? + interval '3 hours')", a.scanned_at),
             %{screened: count(a.id), alarms: filter(count(a.id), a.alarmed)}}
      )
      |> Map.new()

    %{
      totals: Map.put(totals, :secondary, secondary),
      stages: stages,
      lanes:
        Enum.map(lanes(f), fn l ->
          Map.merge(
            %{lane: l, screened: 0, alarms: 0, cleared: 0, detained: 0, in_progress: 0},
            by_lane[l.id] || %{}
          )
        end),
      daily:
        Date.range(f.from, f.to)
        |> Enum.map(&Map.merge(%{date: &1, screened: 0, alarms: 0}, daily[&1] || %{})),
      revenue: revenue(f),
      turnaround: turnaround(f)
    }
  end

  defp revenue(f) do
    apps = in_period(f)

    inv =
      Repo.one(
        from a in apps,
          join: i in Invoice,
          on: i.application_id == a.id,
          select: %{
            invoices: count(i.id),
            raised_kes: coalesce(sum(i.amount_kes), 0),
            paid: filter(count(i.id), i.status == "paid"),
            paid_kes: coalesce(filter(sum(i.amount_kes), i.status == "paid"), 0),
            outstanding_kes: coalesce(filter(sum(i.amount_kes), i.status == "pending"), 0)
          }
      )

    methods =
      Repo.all(
        from a in apps,
          join: i in Invoice,
          on: i.application_id == a.id,
          join: p in Payment,
          on: p.invoice_id == i.id and p.status == "matched",
          group_by: p.method,
          select: {p.method, %{count: count(p.id), kes: sum(p.amount_kes)}}
      )
      |> Map.new()

    Map.put(inv, :methods, methods)
  end

  # Medians, in minutes
  defp turnaround(f) do
    apps = in_period(f)

    median = fn q ->
      Repo.one(q) |> then(&if(&1, do: Float.round(&1 / 60, 1), else: nil))
    end

    %{
      scan_to_clear:
        median.(
          from a in apps,
            where: not is_nil(a.cleared_at),
            select:
              fragment(
                "percentile_cont(0.5) within group (order by extract(epoch from ? - ?))",
                a.cleared_at,
                a.scanned_at
              )
        ),
      alarm_to_decision:
        median.(
          from a in apps,
            join: adj in Adjudication,
            on: adj.application_id == a.id,
            select:
              fragment(
                "percentile_cont(0.5) within group (order by extract(epoch from ? - ?))",
                adj.inserted_at,
                a.scanned_at
              )
        ),
      verification:
        median.(
          from a in apps,
            join: r in Report,
            on: r.application_id == a.id and not is_nil(r.decided_at),
            select:
              fragment(
                "percentile_cont(0.5) within group (order by extract(epoch from ? - ?))",
                r.decided_at,
                r.submitted_at
              )
        )
    }
  end

  @doc "Every container screened in the period (for the detail table and CSV)."
  def screening_rows(f, limit \\ nil) do
    q =
      from a in in_period(f),
        left_join: l in assoc(a, :lane),
        left_join: i in assoc(a, :invoice),
        order_by: [desc: a.scanned_at],
        select: %{
          reference: a.reference,
          container: a.container_number,
          scanned_at: a.scanned_at,
          lane: l.name,
          alarmed: a.alarmed,
          gamma: a.gamma_cps,
          neutron: a.neutron_cps,
          source: a.source,
          stage: a.stage,
          importer: a.importer_name,
          goods: a.goods_description,
          invoice: i.number,
          invoice_status: i.status,
          certificate: a.certificate_number,
          cleared_at: a.cleared_at,
          auto_approved: a.auto_approved
        }

    q = if limit, do: limit(q, ^limit), else: q
    Repo.all(q)
  end

  ## ------------------------------------------------------------------
  ## Events Report (alarms, dispositions, inspections, device faults)

  def events_report(f) do
    apps = in_period(f)
    {start, stop} = bounds(f)

    per_lane =
      Repo.all(
        from a in apps,
          left_join: adj in Adjudication,
          on: adj.application_id == a.id,
          group_by: a.lane_id,
          select:
            {a.lane_id,
             %{
               occupancies: count(a.id),
               manual: filter(count(a.id), a.source == "manual"),
               alarms: filter(count(a.id), a.alarmed),
               active: filter(count(a.id), a.stage == "alarm"),
               released: filter(count(a.id), adj.decision == "release"),
               secondary: filter(count(a.id), adj.decision == "secondary"),
               detained: filter(count(a.id), a.stage == "detained")
             }}
      )
      |> Map.new()

    # Alarms raised before the period that were still open when it began
    prior_open =
      Repo.all(
        from a in Application,
          left_join: adj in Adjudication,
          on: adj.application_id == a.id,
          where:
            a.alarmed and a.scanned_at < ^start and (is_nil(adj.id) or adj.inserted_at >= ^start),
          group_by: a.lane_id,
          select: {a.lane_id, count(a.id)}
      )
      |> Map.new()

    types =
      Repo.all(
        from a in apps,
          where: a.alarmed,
          group_by: a.lane_id,
          select:
            {a.lane_id,
             %{
               gamma:
                 filter(
                   count(a.id),
                   a.gamma_cps > @gamma_threshold and
                     (is_nil(a.neutron_cps) or a.neutron_cps <= @neutron_threshold)
                 ),
               neutron:
                 filter(
                   count(a.id),
                   a.neutron_cps > @neutron_threshold and
                     (is_nil(a.gamma_cps) or a.gamma_cps <= @gamma_threshold)
                 ),
               both:
                 filter(
                   count(a.id),
                   a.gamma_cps > @gamma_threshold and a.neutron_cps > @neutron_threshold
                 ),
               operator:
                 filter(
                   count(a.id),
                   (is_nil(a.gamma_cps) or a.gamma_cps <= @gamma_threshold) and
                     (is_nil(a.neutron_cps) or a.neutron_cps <= @neutron_threshold)
                 )
             }}
      )
      |> Map.new()

    dispositions =
      Repo.all(
        from a in apps,
          join: adj in Adjudication,
          on: adj.application_id == a.id,
          group_by: [a.lane_id, adj.classification],
          select: {a.lane_id, adj.classification, count(a.id)}
      )

    awaiting =
      Repo.all(
        from a in apps,
          where: a.stage == "alarm",
          group_by: a.lane_id,
          select: {a.lane_id, count(a.id)}
      )
      |> Map.new()

    inspections =
      Repo.all(
        from a in apps,
          join: i in Inspection,
          on: i.application_id == a.id,
          group_by: [i.outcome, i.isotope],
          select: {i.outcome, i.isotope, count(i.id)}
      )

    lanes = lanes(f)

    zero = %{
      occupancies: 0,
      manual: 0,
      alarms: 0,
      active: 0,
      released: 0,
      secondary: 0,
      detained: 0
    }

    zero_types = %{gamma: 0, neutron: 0, both: 0, operator: 0}

    %{
      lanes:
        Enum.map(lanes, fn l ->
          Map.merge(zero, per_lane[l.id] || %{})
          |> Map.merge(%{lane: l, prior_open: prior_open[l.id] || 0})
          |> Map.put(:types, Map.merge(zero_types, types[l.id] || %{}))
        end),
      dispositions:
        Enum.map(lanes, fn l ->
          rows =
            for {lane_id, classification, n} <- dispositions,
                lane_id == l.id,
                do: {classification, n}

          rows =
            if (awaiting[l.id] || 0) > 0,
              do: [{"Awaiting adjudication", awaiting[l.id]} | rows],
              else: rows

          {l, Enum.sort_by(rows, &elem(&1, 1), :desc)}
        end)
        |> Enum.reject(fn {_, rows} -> rows == [] end),
      disposition_totals:
        dispositions
        |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
        |> Enum.map(fn {c, ns} -> {c, Enum.sum(ns)} end)
        |> then(fn rows ->
          case Enum.sum(Map.values(awaiting)) do
            0 -> rows
            n -> [{"Awaiting adjudication", n} | rows]
          end
        end)
        |> Enum.sort_by(&elem(&1, 1), :desc),
      inspections: inspections,
      faults: faults(f, lanes, start, stop)
    }
  end

  defp faults(f, lanes, start, stop) do
    codes = Enum.map(lanes, & &1.device_code)

    entries =
      Repo.all(
        from e in Audit.Entry,
          where:
            e.object_type == "device" and e.inserted_at >= ^start and e.inserted_at < ^stop and
              e.object_ref in ^codes and
              e.action in ["Device marked out of service", "Device returned to service"],
          select: {e.object_ref, e.action, e.note}
      )

    by_lane =
      Enum.map(lanes, fn l ->
        mine = Enum.filter(entries, &(elem(&1, 0) == l.device_code))

        %{
          lane: l,
          opened: Enum.count(mine, &(elem(&1, 1) == "Device marked out of service")),
          cleared: Enum.count(mine, &(elem(&1, 1) == "Device returned to service")),
          active: if(l.in_service, do: 0, else: 1)
        }
      end)

    by_reason =
      entries
      |> Enum.filter(&(elem(&1, 1) == "Device marked out of service"))
      |> Enum.group_by(fn {_, _, note} ->
        String.trim(note || "") |> then(&if(&1 == "", do: "No reason given", else: &1))
      end)
      |> Enum.map(fn {reason, es} -> {reason, length(es)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    _ = f
    %{lanes: by_lane, reasons: by_reason}
  end

  ## ------------------------------------------------------------------
  ## CSV

  def screening_csv(f) do
    header =
      ~w(reference container scanned_at_eat lane alarm gamma_cps neutron_cps recorded_by stage importer goods invoice invoice_status certificate cleared_at_eat auto_approved)

    rows =
      for r <- screening_rows(f) do
        [
          r.reference,
          r.container,
          Knra.Time.format(r.scanned_at),
          r.lane,
          if(r.alarmed, do: "yes", else: "no"),
          r.gamma,
          r.neutron,
          if(r.source == "manual", do: "RPM operator", else: "RPM feed"),
          Application.stage_label(r.stage),
          r.importer,
          r.goods,
          r.invoice,
          r.invoice_status,
          r.certificate,
          r.cleared_at && Knra.Time.format(r.cleared_at),
          if(r.auto_approved, do: "yes", else: "no")
        ]
      end

    to_csv([header | rows])
  end

  def events_csv(f) do
    report = events_report(f)

    lane_rows =
      for l <- report.lanes do
        [
          l.lane.name,
          l.lane.device_code,
          l.occupancies,
          l.manual,
          l.alarms,
          l.active,
          l.released,
          l.secondary,
          l.detained,
          l.prior_open,
          l.types.gamma,
          l.types.neutron,
          l.types.both,
          l.types.operator
        ]
      end

    to_csv([
      ~w(lane device occupancies recorded_by_operator total_alarms active_alarms released diverted_secondary detained prior_open_alarms gamma neutron gamma_and_neutron operator_reported)
      | lane_rows
    ])
  end

  defp to_csv(rows) do
    rows
    |> Enum.map_join("\n", fn row -> Enum.map_join(row, ",", &cell/1) end)
    |> Kernel.<>("\n")
  end

  defp cell(nil), do: ""

  defp cell(v) do
    v = to_string(v)

    if String.contains?(v, [",", "\"", "\n"]),
      do: ~s("#{String.replace(v, "\"", "\"\"")}"),
      else: v
  end
end
