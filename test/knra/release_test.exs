defmodule Knra.ReleaseTest do
  use Knra.DataCase, async: false

  import ExUnit.CaptureIO
  import Swoosh.TestAssertions

  alias Knra.{Accounts, Release}

  test "super admin with a password is confirmed, can log in, and gets no email" do
    out =
      capture_io(fn ->
        assert {:ok, _} =
                 Release.create_super_admin("root@knra.test", "Root",
                   password: "a-strong-password-1"
                 )
      end)

    assert out =~ "Log in at"
    assert_no_email_sent()

    user = Accounts.get_user_by_email_and_password("root@knra.test", "a-strong-password-1")
    assert user.role == "super_admin"
    assert user.confirmed_at
  end

  test "a too-short password is refused and nothing is created" do
    out =
      capture_io(fn ->
        assert {:error, [_ | _]} =
                 Release.create_super_admin("root@knra.test", "Root", password: "short")
      end)

    assert out =~ "password should be at least 12 character"
    refute Accounts.get_user_by_email("root@knra.test")
  end

  test "without a password a login link is printed and emailed" do
    out =
      capture_io(fn -> assert {:ok, _} = Release.create_supervisor("sup@knra.test", "Sup") end)

    assert out =~ "/users/log-in/"
    assert_email_sent(to: [{"", "sup@knra.test"}])
    assert Accounts.get_user_by_email("sup@knra.test").role == "supervisor"
  end
end
