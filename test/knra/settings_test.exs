defmodule Knra.SettingsTest do
  use KnraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Knra.ScreeningFixtures

  alias Knra.{Screening, Settings}
  alias Knra.Accounts.Scope

  setup ctx do
    ctx = Map.merge(ctx, setup_screening())

    admin =
      Scope.for_user(Knra.AccountsFixtures.user_fixture(%{role: "super_admin", name: "Root"}))

    op =
      Scope.for_user(
        Knra.AccountsFixtures.user_fixture(%{role: "rpm_operator", name: "J. Mutua"})
      )

    Map.merge(ctx, %{super_admin: admin, rpm_operator: op})
  end

  test "defaults keep today's behaviour" do
    assert Settings.enabled?("rpm_override_enabled")
    refute Settings.enabled?("auto_clear_no_alarm")
    assert Settings.enabled?("auto_clear_wait_for_payment")
  end

  test "only roles with Manage system settings can change them; changes are audited", ctx do
    assert {:error, :unauthorized} = Settings.put(ctx.supervisor, "auto_clear_no_alarm", true)
    assert {:ok, true} = Settings.put(ctx.super_admin, "auto_clear_no_alarm", true)
    assert Settings.enabled?("auto_clear_no_alarm")

    [entry | _] = Knra.Audit.search(%{"object_type" => "setting"})
    assert entry.action == "Auto-clear passes with no alarm: on"
    assert entry.actor_name == "Root"
  end

  describe "Allow Record Anyway" do
    test "when off, passes KenTrade cannot confirm are refused", ctx do
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "ABCU1234560")
      assert Screening.overridable?(lookup)

      {:ok, false} = Settings.put(ctx.super_admin, "rpm_override_enabled", false)
      refute Screening.overridable?(lookup)

      assert {:error, :lookup_required} =
               Screening.record_manual_pass(
                 op,
                 %{
                   "container_number" => "ABCU1234560",
                   "lane_id" => ctx.lane.id,
                   "outcome" => "pass",
                   "override_reason" => "KenTrade has no record yet, container at berth"
                 },
                 lookup,
                 "ABCU1234560"
               )
    end

    test "when off, the Record Anyway button is not offered", ctx do
      {:ok, false} = Settings.put(ctx.super_admin, "rpm_override_enabled", false)
      {:ok, lv, _} = live(log_in_user(ctx.conn, ctx.rpm_operator.user), ~p"/rpm/record")
      lv |> form("#lookup-form", lookup: %{container_number: "ABCU1234560"}) |> render_submit()
      assert render_async(lv) =~ "No KenTrade record"
      refute has_element?(lv, "#record-anyway")
    end
  end

  describe "Auto-clear passes with no alarm" do
    test "no-alarm pass is approved automatically and cleared once the fee is paid", ctx do
      {:ok, true} = Settings.put(ctx.super_admin, "auto_clear_no_alarm", true)

      app = rpm_pass("MSKU7741293")
      assert app.stage == "approved"
      assert app.auto_approved
      assert app.reports == []

      assert Enum.any?(
               Screening.timeline(app),
               &(&1.action == "Approved automatically — no alarm on the RPM pass")
             )

      {:ok, _} = mpesa(app.invoice.number)
      app = reload(app)
      assert app.stage == "cleared"
      assert app.certificate_number
    end

    test "without waiting for payment it is cleared immediately, fee still owed", ctx do
      {:ok, true} = Settings.put(ctx.super_admin, "auto_clear_no_alarm", true)
      {:ok, false} = Settings.put(ctx.super_admin, "auto_clear_wait_for_payment", false)

      app = rpm_pass("MSKU7741293")
      assert app.stage == "cleared"
      assert app.certificate_number
      assert app.invoice.status == "pending"

      cleared =
        Enum.find(Screening.timeline(app), &(&1.action =~ "Cleared — screening certificate"))

      assert cleared.note =~ "still owed"
    end

    test "bulk staging can still reach the report stages", ctx do
      {:ok, true} = Settings.put(ctx.super_admin, "auto_clear_no_alarm", true)

      assert {:ok, %{stage: "report_check"}} =
               Knra.Simulator.Batch.stage(
                 ctx.super_admin,
                 "MSKU7741293",
                 "report_check",
                 "RPM-T-01"
               )
    end

    test "alarms still go to the alarm queue", ctx do
      {:ok, true} = Settings.put(ctx.super_admin, "auto_clear_no_alarm", true)
      assert rpm_pass("TGHU5029184", true).stage == "alarm"
    end

    test "flagged passes are never auto-cleared", ctx do
      {:ok, true} = Settings.put(ctx.super_admin, "auto_clear_no_alarm", true)
      op = ctx.rpm_operator
      lookup = Screening.lookup_for_manual_pass(op, "ABCU1234560")

      {:ok, app} =
        Screening.record_manual_pass(
          op,
          %{
            "container_number" => "ABCU1234560",
            "lane_id" => ctx.lane.id,
            "outcome" => "pass",
            "override_reason" => "Container at berth, KenTrade has no record"
          },
          lookup,
          "ABCU1234560"
        )

      app = reload(app)
      assert app.stage == "report_draft"
      refute app.auto_approved
    end

    test "the application page and certificate say it was approved automatically", ctx do
      {:ok, true} = Settings.put(ctx.super_admin, "auto_clear_no_alarm", true)
      {:ok, false} = Settings.put(ctx.super_admin, "auto_clear_wait_for_payment", false)
      app = rpm_pass("MSKU7741293")

      conn = log_in_user(ctx.conn, ctx.cas_operator.user)
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.reference}")
      assert html =~ "Approved automatically."

      cert = html_response(get(conn, ~p"/applications/#{app.reference}/certificate"), 200)
      assert cert =~ "Approved automatically"
      assert cert =~ "auto-clearance rule"
    end
  end

  describe "System Settings page" do
    test "super admin toggles a setting", ctx do
      {:ok, lv, html} = live(log_in_user(ctx.conn, ctx.super_admin.user), ~p"/admin/settings")
      assert html =~ "Auto-clear passes with no alarm"
      assert has_element?(lv, ~s(#toggle-auto_clear_no_alarm[aria-checked="false"]))

      lv |> element("#toggle-auto_clear_no_alarm") |> render_click()
      assert Settings.enabled?("auto_clear_no_alarm")
      assert has_element?(lv, ~s(#toggle-auto_clear_no_alarm[aria-checked="true"]))
    end

    test "supervisors cannot open it unless granted the permission", ctx do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(ctx.conn, ctx.supervisor.user), ~p"/admin/settings")
    end

    test "the top bar links to Account Settings", ctx do
      {:ok, _lv, html} = live(log_in_user(ctx.conn, ctx.cas_operator.user), ~p"/cas/lanes")
      assert html =~ "Account Settings"
    end
  end
end
