defmodule Knra.ReportingTest do
  use KnraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Knra.ScreeningFixtures

  alias Knra.{Reporting, Screening}

  setup :setup_screening

  defp period, do: Reporting.filters(%{})

  defp seed_events(ctx) do
    # clear pass, cleared
    a = rpm_pass("MSKU7741293")

    {:ok, _} =
      Screening.submit_report(ctx.checking_officer, a, %{"narrative" => "Clear pass, no alarm."})

    {:ok, _} = Screening.approve_report(ctx.verification_officer, a)
    {:ok, _} = mpesa(a.invoice.number)

    # alarm released as NORM
    b = rpm_pass("TGHU5029184", true)

    {:ok, _} =
      Screening.adjudicate(ctx.cas_operator, b, %{
        "decision" => "release",
        "classification" => "NORM (naturally occurring)",
        "reason" => "Consistent with NORM"
      })

    # alarm diverted, inspected, detention recommended
    c = rpm_pass("CMAU1187640", true)

    {:ok, _} =
      Screening.adjudicate(ctx.cas_operator, c, %{
        "decision" => "secondary",
        "classification" => "Unresolved — requires secondary",
        "reason" => "Needs a handheld check"
      })

    {:ok, _} =
      Screening.submit_inspection(ctx.field_officer, c, %{
        "isotope" => "Cs-137",
        "dose_rate_usv_h" => "4.2",
        "findings" => "Source located in rear pallet",
        "outcome" => "detain"
      })

    # alarm still active
    rpm_pass("PONU3345671", true)

    # a device fault and its return
    {:ok, lane} = Knra.Devices.mark_out_of_service(ctx.supervisor, ctx.lane, "RPM Offline")
    {:ok, _} = Knra.Devices.return_to_service(ctx.supervisor, lane)
  end

  test "screening summary counts containers, statuses, lanes, fees and days", ctx do
    seed_events(ctx)
    r = Reporting.screening_summary(period())

    assert r.totals.screened == 4
    assert r.totals.alarms == 3
    assert r.totals.cleared == 1
    assert r.totals.detained == 1
    assert r.totals.in_progress == 2
    assert r.totals.secondary == 1
    assert r.stages["cleared"] == 1
    assert r.stages["alarm"] == 1

    lane = Enum.find(r.lanes, &(&1.lane.id == ctx.lane.id))
    assert lane.screened == 4

    assert r.revenue.invoices == 4
    assert r.revenue.paid == 1
    assert Decimal.equal?(r.revenue.paid_kes, Decimal.new("2600"))
    assert r.revenue.methods["mpesa"].count == 1

    assert Enum.sum(Enum.map(r.daily, & &1.screened)) == 4
    assert length(r.daily) == 30
  end

  test "events report: alarms by lane, types, dispositions, inspections and faults", ctx do
    seed_events(ctx)
    r = Reporting.events_report(period())

    lane = Enum.find(r.lanes, &(&1.lane.id == ctx.lane.id))
    assert %{occupancies: 4, alarms: 3, active: 1, released: 1, secondary: 1, detained: 1} = lane
    assert lane.types.gamma == 3

    assert {"NORM (naturally occurring)", 1} in r.disposition_totals
    assert {"Awaiting adjudication", 1} in r.disposition_totals
    assert {"detain", "Cs-137", 1} in r.inspections

    fault = Enum.find(r.faults.lanes, &(&1.lane.id == ctx.lane.id))
    assert %{opened: 1, cleared: 1, active: 0} = fault
    assert r.faults.reasons == [{"RPM Offline", 1}]
  end

  test "date and lane filters", ctx do
    seed_events(ctx)
    yesterday = Date.add(Knra.Time.today(), -1)

    f = Reporting.filters(%{"from" => "2026-01-01", "to" => Date.to_iso8601(yesterday)})
    assert Reporting.screening_summary(f).totals.screened == 0

    f = Reporting.filters(%{"lane_id" => to_string(ctx.faulty_lane.id)})
    assert Reporting.screening_summary(f).totals.screened == 0
    assert [%{lane: %{id: id}}] = Reporting.events_report(f).lanes
    assert id == ctx.faulty_lane.id
  end

  test "pages and CSV exports need View reports", ctx do
    seed_events(ctx)

    conn = log_in_user(ctx.conn, ctx.supervisor.user)
    {:ok, _lv, html} = live(conn, ~p"/reporting/screening")
    assert html =~ "Screening Summary"
    assert html =~ "MSKU 7741293"

    {:ok, lv, html} = live(conn, ~p"/reporting/events")
    assert html =~ "Details of Events by Lane"
    assert html =~ "NORM (naturally occurring)"

    lv
    |> element("#report-filters")
    |> render_change(%{"from" => "2026-01-01", "to" => "2026-01-31"})

    assert_patch(lv, "/reporting/events?from=2026-01-01&to=2026-01-31")

    csv = conn |> get(~p"/reporting/screening/export") |> response(200)
    assert csv =~ "reference,container"
    assert csv =~ "MSKU7741293"

    assert [_ | _] = Knra.Audit.search(%{"object_type" => "report"})

    other = log_in_user(build_conn(), ctx.cas_operator.user)
    assert {:error, {:redirect, %{to: "/"}}} = live(other, ~p"/reporting/screening")
    assert redirected_to(get(other, ~p"/reporting/events/export")) == "/"
  end
end
