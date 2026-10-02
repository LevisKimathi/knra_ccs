defmodule KnraWeb.RpmPassLiveTest do
  use KnraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Knra.ScreeningFixtures
  import Knra.DataCase, only: [errors_on: 1]

  alias Knra.Screening
  alias Knra.Accounts.Scope

  setup ctx do
    ctx = Map.merge(ctx, setup_screening())

    op =
      Scope.for_user(
        Knra.AccountsFixtures.user_fixture(%{role: "rpm_operator", name: "J. Mutua"})
      )

    Map.put(ctx, :rpm_operator, op)
  end

  describe "Screening.record_manual_pass/3" do
    test "records a clear pass using the KenTrade result from the lookup", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "MSKU 774-1293")
      assert {:ok, %{status: "FOUND"}} = lookup

      assert {:ok, app} =
               Screening.record_manual_pass(
                 op,
                 %{
                   "container_number" => "MSKU7741293",
                   "lane_id" => ctx.lane.id,
                   "outcome" => "pass"
                 },
                 lookup
               )

      app = reload(app)
      assert app.stage == "report_draft"
      assert app.source == "manual"
      assert app.recorded_by_id == op.user.id
      assert is_nil(app.gamma_cps) and is_nil(app.neutron_cps)
      assert app.lookup_status == "found"
      assert app.importer_name == "RIFT VALLEY MOTORS LTD"
      assert app.invoice.status == "pending"
      assert app.occupancy_ref =~ ~r/^MAN-/

      actions = app |> Screening.timeline() |> Enum.map(&{&1.actor_name, &1.action, &1.note})

      assert Enum.any?(actions, fn {who, a, _} ->
               who == "J. Mutua" and a =~ "RPM pass recorded by RPM operator"
             end)

      assert Enum.any?(actions, fn {_, a, n} ->
               a =~ "no alarm" and n == "No RIID reading recorded"
             end)

      # KenTrade was called once (the operator's lookup), not again after recording
      assert length(Knra.Integrations.list_logs(%{"q" => "MSKU7741293"})) == 1
    end

    test "an alarm with a RIID reading goes to the alarm queue", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "TGHU5029184")

      {:ok, app} =
        Screening.record_manual_pass(
          op,
          %{
            "container_number" => "TGHU5029184",
            "lane_id" => ctx.lane.id,
            "outcome" => "alarm",
            "gamma_cps" => "190",
            "neutron_cps" => ""
          },
          lookup
        )

      app = reload(app)
      assert app.stage == "alarm"
      assert app.gamma_cps == 190
      assert is_nil(app.neutron_cps)
      assert [%{reference: ref}] = Screening.list_by_stage("alarm")
      assert ref == app.reference
    end

    test "refuses without a FOUND lookup for the same container", ctx do
      op = ctx.rpm_operator

      params = %{
        "container_number" => "MSKU7741293",
        "lane_id" => ctx.lane.id,
        "outcome" => "pass"
      }

      assert {:error, :lookup_required} = Screening.record_manual_pass(op, params, nil)

      not_found = Screening.lookup_for_manual_pass(op, "ABCU1234560")
      assert {:error, :lookup_required} = Screening.record_manual_pass(op, params, not_found)

      other = Screening.lookup_for_manual_pass(op, "TGHU5029184")
      assert {:error, :lookup_required} = Screening.record_manual_pass(op, params, other)
    end

    test "requires lane and result; readings must not be negative", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "MSKU7741293")

      assert {:error, %Ecto.Changeset{} = cs} =
               Screening.record_manual_pass(
                 op,
                 %{"container_number" => "MSKU7741293", "gamma_cps" => "-1"},
                 lookup
               )

      assert %{lane_id: [_], outcome: [_], gamma_cps: [_]} = errors_on(cs)
    end

    test "only RPM operators (and super admins) may record passes", ctx do
      assert {:error, :unauthorized} =
               Screening.lookup_for_manual_pass(ctx.cas_operator, "MSKU7741293")

      lookup = Screening.lookup_for_manual_pass(ctx.rpm_operator, "MSKU7741293")

      assert {:error, :unauthorized} =
               Screening.record_manual_pass(
                 ctx.cas_operator,
                 %{
                   "container_number" => "MSKU7741293",
                   "lane_id" => ctx.lane.id,
                   "outcome" => "pass"
                 },
                 lookup
               )
    end
  end

  describe "Record RPM Pass page" do
    test "look up, record a pass, and see it in recent passes", ctx do
      conn = log_in_user(ctx.conn, ctx.rpm_operator.user)
      assert redirected_to(get(conn, ~p"/")) == ~p"/rpm/record"

      {:ok, lv, _} = live(conn, ~p"/rpm/record")
      refute has_element?(lv, "#pass-form")

      lv |> form("#lookup-form", lookup: %{container_number: "msku7741293"}) |> render_submit()
      html = render_async(lv)
      assert html =~ "Found in KenTrade"
      assert html =~ "RIFT VALLEY MOTORS LTD"
      assert has_element?(lv, "#pass-form")

      lv
      |> form("#pass-form",
        pass: %{lane_id: ctx.lane.id, outcome: "pass", gamma_cps: "", neutron_cps: ""}
      )
      |> render_submit()

      html = render(lv)
      assert html =~ "MSKU 7741293 recorded as CCS-"
      assert html =~ "sent for the screening report"
      assert has_element?(lv, "[id^=recent-CCS-]")
      refute has_element?(lv, "#pass-form")
    end

    test "evidence photos are stored and attached", ctx do
      conn = log_in_user(ctx.conn, ctx.rpm_operator.user)
      {:ok, lv, _} = live(conn, ~p"/rpm/record")

      lv |> form("#lookup-form", lookup: %{container_number: "MSKU7741293"}) |> render_submit()
      render_async(lv)

      photo =
        file_input(lv, "#pass-form", :evidence, [
          %{name: "seal.jpg", content: "fake-jpeg-bytes", type: "image/jpeg"}
        ])

      render_upload(photo, "seal.jpg")

      lv |> form("#pass-form", pass: %{lane_id: ctx.lane.id, outcome: "alarm"}) |> render_submit()

      [app] = Screening.list_manual_passes(ctx.rpm_operator)
      app = reload(app)
      assert [name] = app.evidence_photos
      assert name =~ ~r/^rpm-.*\.jpg$/

      conn =
        get(
          log_in_user(build_conn(), ctx.cas_operator.user),
          ~p"/applications/#{app.reference}/photos/#{name}"
        )

      assert response(conn, 200) == "fake-jpeg-bytes"
    end

    test "a not-found container cannot be recorded", ctx do
      {:ok, lv, _} = live(log_in_user(ctx.conn, ctx.rpm_operator.user), ~p"/rpm/record")
      lv |> form("#lookup-form", lookup: %{container_number: "ABCU1234560"}) |> render_submit()
      assert render_async(lv) =~ "No KenTrade record"
      refute has_element?(lv, "#pass-form")
    end

    test "other roles cannot open the page", ctx do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(ctx.conn, ctx.cas_operator.user), ~p"/rpm/record")
    end
  end

  describe "record anyway (no KenTrade confirmation)" do
    defp params(ctx, extra \\ %{}),
      do:
        Map.merge(
          %{"container_number" => "ABCU1234560", "lane_id" => ctx.lane.id, "outcome" => "pass"},
          extra
        )

    test "a not-found container can be recorded with a reason and is flagged", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "ABCU1234560")
      assert Screening.overridable?(lookup)

      {:ok, app} =
        Screening.record_manual_pass(
          op,
          params(ctx, %{"override_reason" => "Discharged this morning, not yet on KenTrade"}),
          lookup,
          "ABCU1234560"
        )

      app = reload(app)
      assert app.review_status == "pending"
      assert app.override_reason == "Discharged this morning, not yet on KenTrade"
      assert app.lookup_status == "not_found"
      assert app.stage == "report_draft"
      assert Screening.count_flagged() == 1

      assert Enum.any?(
               Screening.timeline(app),
               &(&1.action == "Recorded without KenTrade confirmation — flagged for review")
             )
    end

    test "the reason is mandatory (10+ characters)", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "ABCU1234560")

      assert {:error, %Ecto.Changeset{} = cs} =
               Screening.record_manual_pass(
                 op,
                 params(ctx, %{"override_reason" => "short"}),
                 lookup,
                 "ABCU1234560"
               )

      assert %{override_reason: [_]} = errors_on(cs)
      assert Screening.count_flagged() == 0
    end

    test "KenTrade being unavailable can be overridden; the lookup must match the container",
         ctx do
      op = ctx.rpm_operator
      down = Screening.lookup_for_manual_pass(op, "ERRU0000000")
      assert {:error, %{status: "ERROR"}} = down

      reason = %{"override_reason" => "KenTrade down since 09:00, container at the berth"}

      assert {:error, :lookup_required} =
               Screening.record_manual_pass(op, params(ctx, reason), down, "ERRU0000000")

      assert {:ok, _} =
               Screening.record_manual_pass(
                 op,
                 params(ctx, Map.put(reason, "container_number", "ERRU0000000")),
                 down,
                 "ERRU0000000"
               )
    end

    test "an invalid number format cannot be overridden", ctx do
      assert {:error, :invalid_container_number} =
               Screening.lookup_for_manual_pass(ctx.rpm_operator, "12345")

      refute Screening.overridable?({:error, :invalid_container_number})
    end

    test "supervisor reviews a flagged pass; others cannot", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "ABCU1234560")

      {:ok, app} =
        Screening.record_manual_pass(
          op,
          params(ctx, %{"override_reason" => "Not on KenTrade yet, confirmed by manifest"}),
          lookup,
          "ABCU1234560"
        )

      assert {:error, :unauthorized} = Screening.mark_reviewed(ctx.cas_operator, app, "ok")

      assert {:ok, %{review_status: "reviewed"}} =
               Screening.mark_reviewed(ctx.supervisor, app, "Checked manifest copy")

      assert {:error, :not_flagged} = Screening.mark_reviewed(ctx.supervisor, app, nil)

      app = reload(app)
      assert app.reviewed_by_id == ctx.supervisor.user.id
      assert app.review_note == "Checked manifest copy"
      assert Screening.count_flagged() == 0
    end

    test "page: Record Anyway reveals the reason and records a flagged pass", ctx do
      {:ok, lv, _} = live(log_in_user(ctx.conn, ctx.rpm_operator.user), ~p"/rpm/record")

      lv |> form("#lookup-form", lookup: %{container_number: "ABCU1234560"}) |> render_submit()
      render_async(lv)
      refute has_element?(lv, "#pass-form")

      lv |> element("#record-anyway") |> render_click()
      assert has_element?(lv, "#pass-form textarea[name='pass[override_reason]']")

      html =
        lv
        |> form("#pass-form", pass: %{lane_id: ctx.lane.id, outcome: "pass", override_reason: ""})
        |> render_submit()

      assert html =~ "at least 10 characters"

      lv
      |> form("#pass-form",
        pass: %{
          lane_id: ctx.lane.id,
          outcome: "pass",
          override_reason: "Container at berth; KenTrade has no record yet"
        }
      )
      |> render_submit()

      assert render(lv) =~ "flagged for supervisor review"
      assert [%{review_status: "pending"}] = Screening.list_flagged()
    end

    test "page: supervisor sees Flagged Passes and marks one reviewed", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "ABCU1234560")

      {:ok, app} =
        Screening.record_manual_pass(
          op,
          params(ctx, %{"override_reason" => "Not on KenTrade yet, confirmed by manifest"}),
          lookup,
          "ABCU1234560"
        )

      conn = log_in_user(ctx.conn, ctx.supervisor.user)
      {:ok, list, html} = live(conn, ~p"/reviews")
      assert html =~ "Not on KenTrade yet, confirmed by manifest"
      assert has_element?(list, "#flagged-#{app.reference}")

      {:ok, show, html} = live(conn, ~p"/applications/#{app.reference}")
      assert html =~ "Flagged for review"

      show |> form("#review-form", review: %{note: "Checked"}) |> render_submit()
      assert render(show) =~ "reviewed"
      assert Screening.count_flagged() == 0
    end
  end
end
