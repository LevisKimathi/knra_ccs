defmodule Knra.SuperAdminTest do
  use KnraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Knra.ScreeningFixtures

  alias Knra.{Accounts, Billing, Screening}
  alias Knra.Accounts.{Policy, Scope}

  setup ctx do
    ctx = Map.merge(ctx, setup_screening())

    admin =
      Scope.for_user(Knra.AccountsFixtures.user_fixture(%{role: "super_admin", name: "Root"}))

    Map.put(ctx, :super_admin, admin)
  end

  defp url_fun, do: &"/users/log-in/#{&1}"

  test "has every permission", %{super_admin: admin} do
    for p <- Policy.permissions(), do: assert(Policy.can?(admin, p), "missing #{p}")
  end

  test "can run every workflow step, but still cannot verify a report they drafted", ctx do
    admin = ctx.super_admin
    app = rpm_pass("TGHU5029184", true)

    {:ok, _} =
      Screening.adjudicate(admin, app, %{
        "decision" => "release",
        "classification" => "NORM (naturally occurring)",
        "reason" => "Consistent with NORM"
      })

    {:ok, _} =
      Screening.submit_report(admin, app, %{"narrative" => "Released after adjudication."})

    assert {:error, :segregation_of_duties} = Screening.approve_report(admin, app)
    assert {:ok, %{stage: "approved"}} = Screening.approve_report(ctx.verification_officer, app)
  end

  test "cannot approve their own fee proposal", %{super_admin: admin} do
    {:ok, s} =
      Billing.propose_fee_schedule(admin, %{
        "effective_from" => Date.to_iso8601(Date.add(Knra.Time.today(), 1)),
        "note" => "Gazette 2",
        "items" => %{
          "0" => %{
            "code" => "screening",
            "description" => "Screening",
            "amount_usd" => "25",
            "amount_kes" => "3250"
          }
        }
      })

    assert {:error, :segregation_of_duties} = Billing.approve_fee_schedule(admin, s)
  end

  describe "super admin accounts are protected from supervisors" do
    test "supervisors cannot create, promote, edit, suspend or reset a super admin", ctx do
      sup = ctx.supervisor
      admin_user = ctx.super_admin.user

      assert {:error, :unauthorized} =
               Accounts.create_user(
                 sup,
                 %{"email" => "x@knra.test", "name" => "X", "role" => "super_admin"},
                 url_fun()
               )

      assert {:error, :unauthorized} =
               Accounts.update_user(sup, ctx.cas_operator.user, %{"role" => "super_admin"})

      assert {:error, :unauthorized} =
               Accounts.update_user(sup, admin_user, %{"name" => "Hacked"})

      assert {:error, :unauthorized} = Accounts.set_user_status(sup, admin_user, "suspended")
      assert {:error, :unauthorized} = Accounts.force_password_reset(sup, admin_user, url_fun())
    end

    test "supervisors still manage ordinary staff", ctx do
      assert {:ok, _} =
               Accounts.set_user_status(ctx.supervisor, ctx.cas_operator.user, "suspended")
    end

    test "a super admin can create and manage super admins and supervisors", ctx do
      admin = ctx.super_admin

      assert {:ok, other} =
               Accounts.create_user(
                 admin,
                 %{"email" => "root2@knra.test", "name" => "Root 2", "role" => "super_admin"},
                 url_fun()
               )

      assert other.role == "super_admin"

      assert {:ok, {%{status: "suspended"}, _}} =
               Accounts.set_user_status(admin, other, "suspended")

      assert {:ok, _} =
               Accounts.update_user(admin, ctx.supervisor.user, %{"station" => "Mombasa"})
    end

    test "the Users page hides super admin actions and role from supervisors", ctx do
      conn = log_in_user(ctx.conn, ctx.supervisor.user)
      {:ok, lv, html} = live(conn, ~p"/admin/users")

      assert html =~ "Managed by super admins"
      refute html =~ ~s(href="/admin/users/#{ctx.super_admin.user.id}/edit")

      {:ok, form_lv, _} = live(conn, ~p"/admin/users/new")
      assert has_element?(form_lv, "#user-form option[value=supervisor]")
      refute has_element?(form_lv, "#user-form option[value=super_admin]")

      assert {:error, {:live_redirect, %{to: "/admin/users", flash: %{"error" => _}}}} =
               live(conn, ~p"/admin/users/#{ctx.super_admin.user.id}/edit")

      _ = lv
    end
  end

  test "home and navigation", ctx do
    conn = log_in_user(ctx.conn, ctx.super_admin.user)
    assert redirected_to(get(conn, ~p"/")) == ~p"/cas/lanes"

    {:ok, _lv, html} = live(log_in_user(build_conn(), ctx.super_admin.user), ~p"/cas/lanes")

    for label <- [
          "Alarm queue",
          "Secondary inspections",
          "Screening reports",
          "Users &amp; roles",
          "Audit trail"
        ] do
      assert html =~ label
    end
  end
end
