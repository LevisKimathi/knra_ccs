defmodule Knra.RolesTest do
  use KnraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Knra.ScreeningFixtures
  import Knra.DataCase, only: [errors_on: 1]

  alias Knra.Accounts.{Policy, Roles, Scope}

  setup ctx do
    ctx = Map.merge(ctx, setup_screening())

    admin =
      Scope.for_user(Knra.AccountsFixtures.user_fixture(%{role: "super_admin", name: "Root"}))

    Map.put(ctx, :super_admin, admin)
  end

  defp role(key), do: Enum.find(Roles.list_roles(), &(&1.key == key))

  test "built-in roles keep the permissions they had in code", ctx do
    assert Policy.can?(ctx.cas_operator, :adjudicate)
    refute Policy.can?(ctx.cas_operator, :verify_report)
    assert Policy.can?(ctx.verification_officer, :verify_report)
    refute Policy.can?(ctx.verification_officer, :draft_report)
    assert Policy.can?(ctx.supervisor, :manage_users)
    assert Policy.can?(ctx.supervisor, :receive_alert_emails)
    refute Policy.can?(ctx.supervisor, :adjudicate)
  end

  test "only super admins manage roles; it cannot be granted", ctx do
    assert Policy.can?(ctx.super_admin, :manage_roles)
    refute Policy.can?(ctx.supervisor, :manage_roles)
    refute "manage_roles" in Policy.grantable_keys()

    assert {:error, :unauthorized} =
             Roles.update_role(ctx.supervisor, role("cas_operator"), %{"name" => "X"})
  end

  test "editing a role changes what its users can do immediately, and is audited", ctx do
    refute Policy.can?(ctx.field_officer, :view_lanes)

    {:ok, _} =
      Roles.update_role(ctx.super_admin, role("field_officer"), %{
        "permissions" => role("field_officer").permissions ++ ["view_lanes"]
      })

    assert Policy.can?(ctx.field_officer, :view_lanes)

    [entry | _] = Knra.Audit.search(%{"object_type" => "role"})
    assert entry.action == "Role updated — Field inspection officer"
    assert entry.note =~ "added: Lane overview and alarm queue"
  end

  test "a role cannot both draft and verify reports", ctx do
    assert {:error, cs} =
             Roles.update_role(ctx.super_admin, role("checking_officer"), %{
               "permissions" => ["view_applications", "draft_report", "verify_report"]
             })

    assert %{permissions: [msg]} = errors_on(cs)
    assert msg =~ "maker"
  end

  test "unknown permissions are refused", ctx do
    assert {:error, cs} =
             Roles.create_role(ctx.super_admin, %{"name" => "Odd", "permissions" => ["fly"]})

    assert %{permissions: [_]} = errors_on(cs)
  end

  test "the super admin role cannot be edited or deleted", ctx do
    assert {:error, :super_admin_role} =
             Roles.update_role(ctx.super_admin, role("super_admin"), %{"name" => "Boss"})

    assert {:error, :built_in_role} = Roles.delete_role(ctx.super_admin, role("super_admin"))
  end

  test "a custom role can be created, assigned, and deleted once unused", ctx do
    {:ok, shift} =
      Roles.create_role(ctx.super_admin, %{
        "name" => "Shift supervisor",
        "description" => "Night shift oversight",
        "permissions" => ["view_applications", "view_lanes", "monitor_queues"]
      })

    assert shift.key == "shift_supervisor"
    assert {"Shift supervisor", "shift_supervisor"} in Roles.options()

    user = Knra.AccountsFixtures.user_fixture(%{role: "shift_supervisor"})
    scope = Scope.for_user(user)
    assert Policy.can?(scope, :view_lanes)
    refute Policy.can?(scope, :adjudicate)
    assert KnraWeb.Nav.home_path(scope) == "/cas/lanes"

    labels =
      scope |> KnraWeb.Nav.sections() |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(& &1.label)

    assert "Alarm Queue" in labels
    assert "Secondary Inspections" in labels
    refute "Record RPM Pass" in labels

    assert {:error, :role_in_use} = Roles.delete_role(ctx.super_admin, shift)
    assert {:error, :built_in_role} = Roles.delete_role(ctx.super_admin, role("cas_operator"))

    {:ok, _} = Knra.Accounts.update_user(ctx.super_admin, user, %{"role" => "cas_operator"})
    assert {:ok, _} = Roles.delete_role(ctx.super_admin, Roles.get_role!(shift.id))
    refute Roles.exists?("shift_supervisor")
  end

  test "users can only be given a role that exists", ctx do
    assert {:error, cs} =
             Knra.Accounts.create_user(
               ctx.super_admin,
               %{"email" => "a@b.ke", "name" => "A", "role" => "pilot"},
               & &1
             )

    assert %{role: ["is not a known role"]} = errors_on(cs)
  end

  test "notices reach users by permission, with one id per notice", ctx do
    Knra.Notifications.subscribe(ctx.supervisor)
    Knra.Notifications.notify([:view_lanes, :manage_devices], :error, "Lane 2 down")

    # The supervisor holds both permissions, so it arrives twice with the same id
    assert_receive {:notification, %{id: id, message: "Lane 2 down"}}
    assert_receive {:notification, %{id: ^id}}
  end

  test "alert emails go to roles with Receive alert emails", ctx do
    recipients =
      Knra.Accounts.list_active_users_with_permission(:receive_alert_emails) |> Enum.map(& &1.id)

    assert ctx.supervisor.user.id in recipients
    assert ctx.super_admin.user.id in recipients
    refute ctx.cas_operator.user.id in recipients
  end

  describe "Roles & Permissions page" do
    test "super admin edits a role's permissions with checkboxes", ctx do
      {:ok, _lv, html} = live(log_in_user(ctx.conn, ctx.super_admin.user), ~p"/admin/roles")
      assert html =~ "CAS operator"
      assert html =~ "All permissions"

      r = role("rpm_operator")

      {:ok, lv, _} =
        live(log_in_user(build_conn(), ctx.super_admin.user), ~p"/admin/roles/#{r.id}/edit")

      assert has_element?(lv, "#perm-record_rpm_pass[checked]")

      lv
      |> form("#role-form",
        role: %{
          name: "RPM operator",
          permissions: ["", "view_applications", "record_rpm_pass", "print_documents"]
        }
      )
      |> render_submit()

      assert "print_documents" in Roles.get_role!(r.id).permissions
    end

    test "supervisors cannot open it", ctx do
      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(ctx.conn, ctx.supervisor.user), ~p"/admin/roles")
    end
  end
end
