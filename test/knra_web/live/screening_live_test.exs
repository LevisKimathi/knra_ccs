defmodule KnraWeb.ScreeningLiveTest do
  use KnraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Knra.ScreeningFixtures

  setup :setup_screening

  defp as(conn, scope), do: log_in_user(conn, scope.user)

  describe "role-based access" do
    test "home sends each role to its work screen", ctx do
      assert redirected_to(get(as(ctx.conn, ctx.cas_operator), ~p"/")) == ~p"/cas/lanes"
      assert redirected_to(get(as(ctx.conn, ctx.field_officer), ~p"/")) == ~p"/inspections"
      assert redirected_to(get(as(ctx.conn, ctx.checking_officer), ~p"/")) == ~p"/reports"
    end

    test "screens outside a role redirect with an error", ctx do
      assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} =
               live(as(ctx.conn, ctx.field_officer), ~p"/cas/lanes")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(as(ctx.conn, ctx.cas_operator), ~p"/admin/users")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(as(ctx.conn, ctx.checking_officer), ~p"/admin/audit")
    end

    test "suspended users are logged out", ctx do
      conn = as(ctx.conn, ctx.cas_operator)

      {:ok, {_, _}} =
        Knra.Accounts.set_user_status(ctx.supervisor, ctx.cas_operator.user, "suspended")

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/cas/lanes")
    end

    test "there is no self-registration", %{conn: conn} do
      assert conn |> get("/users/register") |> response(404)
    end
  end

  describe "CAS adjudication screen" do
    test "requires a reason, then diverts to secondary", ctx do
      app = rpm_pass("TGHU5029184", true)
      {:ok, lv, html} = live(as(ctx.conn, ctx.cas_operator), ~p"/applications/#{app.reference}")
      assert html =~ "COAST STEEL MILLS LTD"

      html =
        lv
        |> form("#adjudication-form", adjudication: %{classification: "", reason: ""})
        |> render_submit(%{"adjudication" => %{"decision" => "secondary"}})

      assert html =~ "is required"
      assert reload(app).stage == "alarm"

      lv
      |> form("#adjudication-form",
        adjudication: %{
          classification: "Unresolved — requires secondary",
          reason: "Needs a handheld check"
        }
      )
      |> render_submit(%{"adjudication" => %{"decision" => "secondary"}})

      assert reload(app).stage == "secondary"
      assert render(lv) =~ "Diverted to secondary inspection"
    end

    test "other roles see the application without the adjudication form", ctx do
      app = rpm_pass("TGHU5029184", true)

      {:ok, lv, html} =
        live(as(ctx.conn, ctx.checking_officer), ~p"/applications/#{app.reference}")

      refute has_element?(lv, "#adjudication-form")
      assert html =~ "Awaiting adjudication by a CAS operator"
    end
  end

  describe "maker–checker screen" do
    test "checking officer submits, verification officer approves", ctx do
      app = rpm_pass("MSKU7741293")

      {:ok, lv, _} = live(as(ctx.conn, ctx.checking_officer), ~p"/applications/#{app.reference}")

      lv
      |> form("#report-form", report: %{narrative: "Clear pass, no alarm, counts at background."})
      |> render_submit()

      assert reload(app).stage == "report_check"

      {:ok, lv, _} =
        live(as(build_conn(), ctx.verification_officer), ~p"/applications/#{app.reference}")

      lv |> element("#approve-report") |> render_click()
      assert reload(app).stage == "approved"
    end

    test "rejecting without a reason is refused", ctx do
      app = rpm_pass("MSKU7741293")

      {:ok, _} =
        Knra.Screening.submit_report(ctx.checking_officer, app, %{
          "narrative" => "Clear pass, no alarm."
        })

      {:ok, lv, _} =
        live(as(ctx.conn, ctx.verification_officer), ~p"/applications/#{app.reference}")

      assert lv |> form("#reject-form", rejection: %{rejection_reason: ""}) |> render_submit() =~
               "is required"

      assert reload(app).stage == "report_check"
    end
  end

  describe "documents" do
    test "certificate is only available once cleared", ctx do
      app = rpm_pass("MSKU7741293")
      conn = as(ctx.conn, ctx.cas_operator)

      assert redirected_to(get(conn, ~p"/applications/#{app.reference}/certificate")) ==
               ~p"/applications/#{app.reference}"

      assert html_response(get(conn, ~p"/applications/#{app.reference}/invoice"), 200) =~
               app.invoice.number

      {:ok, _} =
        Knra.Screening.submit_report(ctx.checking_officer, app, %{
          "narrative" => "Clear pass, no alarm."
        })

      {:ok, _} = Knra.Screening.approve_report(ctx.verification_officer, app)
      {:ok, _} = mpesa(app.invoice.number)

      cleared = reload(app)
      html = html_response(get(conn, ~p"/applications/#{app.reference}/certificate"), 200)
      assert html =~ cleared.certificate_number
      assert html =~ "no radiological objection"
    end

    test "public verification finds cleared certificates only", ctx do
      app = rpm_pass("MSKU7741293")

      {:ok, _} =
        Knra.Screening.submit_report(ctx.checking_officer, app, %{
          "narrative" => "Clear pass, no alarm."
        })

      {:ok, _} = Knra.Screening.approve_report(ctx.verification_officer, app)
      {:ok, _} = mpesa(app.invoice.number)
      number = reload(app).certificate_number

      {:ok, lv, _} = live(build_conn(), ~p"/verify")

      assert lv |> form("#verify-form", verify: %{number: number}) |> render_submit() =~
               "Valid certificate"

      assert lv
             |> form("#verify-form", verify: %{number: "KNRA/CCS/2026/999999"})
             |> render_submit() =~ "No certificate found"
    end

    test "audit export is supervisor-only", ctx do
      assert redirected_to(get(as(ctx.conn, ctx.cas_operator), ~p"/admin/audit/export")) == ~p"/"
      conn = get(as(build_conn(), ctx.supervisor), ~p"/admin/audit/export")
      assert response(conn, 200) =~ "time_utc,object_type"
    end
  end

  describe "simulator" do
    test "an RPM pass opens the application", ctx do
      {:ok, lv, _} = live(as(ctx.conn, ctx.cas_operator), ~p"/simulator")

      assert {:error, {:live_redirect, %{to: "/applications/" <> _}}} =
               lv
               |> form("#rpm-form", rpm: %{container: "OOLU4471228", lane: "auto", alarm: "true"})
               |> render_submit()

      assert [%{container_number: "OOLU4471228", stage: "alarm"}] =
               Knra.Screening.list_by_stage("alarm")
    end

    test "bulk staging shows each container's result and status API answer", ctx do
      admin = Knra.AccountsFixtures.user_fixture(%{role: "super_admin", name: "Root"})
      {:ok, lv, _} = live(log_in_user(ctx.conn, admin), ~p"/simulator")

      html =
        lv
        |> form("#batch-form", batch: %{text: "MRKU9937602 cleared\nINBU5333934 detained"})
        |> render_submit()

      assert html =~ "2 of 2 containers staged"
      assert html =~ "CLEARED"
      assert html =~ "DETAINED"

      html =
        lv
        |> form("#batch-form", batch: %{text: "MRKU9937602 cleared"})
        |> render_submit()

      assert html =~ "(already there)"

      assert render_submit(
               form(
                 as(ctx.conn, ctx.supervisor) |> live(~p"/simulator") |> elem(1),
                 "#batch-form", batch: %{text: "MRKU2415627"})
             ) =~
               "must be run by a super admin"
    end
  end
end
