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

  test "seed_lanes registers the four lanes once and is safe to re-run" do
    assert {%{added: 4}, _} = with_io(&Release.seed_lanes/0)
    assert {%{skipped: 4}, out} = with_io(&Release.seed_lanes/0)
    assert out =~ "already registered"

    lanes = Knra.Devices.list_lanes()
    assert Enum.map(lanes, & &1.device_code) == ~w(RPM-MSA-01 RPM-MSA-02 RPM-MSA-03 RPM-MSA-04)
    assert Enum.all?(lanes, & &1.in_service)
    assert [_ | _] = Knra.Audit.search(%{"object_type" => "device"})
  end

  test "simulate_statuses stages containers as the first super admin and prints a table" do
    Knra.ScreeningFixtures.setup_screening()
    Knra.AccountsFixtures.user_fixture(%{role: "super_admin", name: "Root"})

    {result, out} =
      with_io(fn ->
        Release.simulate_statuses("MRKU9937602 cleared, INBU5333934", default: "alarm")
      end)

    assert result == {:ok, 2, 0}
    assert out =~ ~r/MRKU9937602\s+CLEARED\s+CLEARED/
    assert out =~ ~r/INBU5333934\s+IN_PROGRESS\/Alarm.*\s+IN_PROGRESS\/ALARM_ADJUDICATION/
  end
end
