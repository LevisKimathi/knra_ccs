defmodule Knra.Simulator.BatchTest do
  use Knra.DataCase, async: false

  import Knra.AccountsFixtures
  import Knra.ScreeningFixtures

  alias Knra.Accounts.Scope
  alias Knra.Simulator.Batch

  setup :setup_screening

  setup do
    %{admin: Scope.for_user(user_fixture(%{role: "super_admin", name: "Root"}))}
  end

  test "parse accepts lines, separators, API names and keeps the last status for repeats" do
    text = """
    MRKU9937602 cleared
    INBU5333934=DETAINED, MRKU2415627: awaiting_payment
    mrku 991-0001
    MRKU9937602 IN_PROGRESS
    """

    assert Batch.parse(text) ==
             {[
                {"MRKU9937602", "report_draft"},
                {"INBU5333934", "detained"},
                {"MRKU2415627", "approved"},
                {"MRKU9910001", nil}
              ], []}

    assert {_, ["bogus"]} = Batch.parse("MRKU9937602 bogus")
  end

  test "stages each container at its target and the status API reports it", %{admin: admin} do
    text = """
    MRKU0000001 alarm
    MRKU0000002 secondary
    MRKU0000003 report_draft
    MRKU0000004 report_check
    MRKU0000005 approved
    MRKU0000006 cleared
    MRKU0000007 detained
    """

    assert {:ok, results} = Batch.run(admin, text, lane: "RPM-T-01")

    stages = Enum.map(results, fn %{result: {:ok, app}} -> app.stage end)
    assert stages == ~w(alarm secondary report_draft report_check approved cleared detained)

    api = Enum.map(results, & &1.api["status"])

    assert api ==
             ~w(IN_PROGRESS IN_PROGRESS IN_PROGRESS IN_PROGRESS IN_PROGRESS CLEARED DETAINED)

    cleared = Enum.at(results, 5)
    assert cleared.api["certificateNumber"] =~ "KNRA/CCS/"
  end

  test "the four API statuses, including NOT_FOUND", %{admin: admin} do
    text =
      "MRKU0000001 CLEARED, MRKU0000002 DETAINED, MRKU0000003 IN_PROGRESS, MRKU0000004 NOT_FOUND"

    assert {:ok, results} = Batch.run(admin, text, lane: "RPM-T-01")
    assert Enum.map(results, & &1.api["status"]) == ~w(CLEARED DETAINED IN_PROGRESS NOT_FOUND)
    assert List.last(results).result == :not_screened

    assert {:ok,
            [%{result: {:error, {:already_screened, "cleared"}}, api: %{"status" => "CLEARED"}}]} =
             Batch.run(admin, "MRKU0000001 NOT_FOUND", lane: "RPM-T-01")
  end

  test "containers without a status are spread; re-running is a no-op", %{admin: admin} do
    text = Enum.map_join(1..4, "\n", &"MSKU#{String.pad_leading("#{&1}", 7, "0")}")

    assert {:ok, results} = Batch.run(admin, text, lane: "RPM-T-01")
    assert Enum.map(results, & &1.target) == Batch.spread_order()
    assert Enum.map(results, & &1.api["status"]) == ~w(CLEARED DETAINED IN_PROGRESS NOT_FOUND)

    assert {:ok, again} = Batch.run(admin, text, lane: "RPM-T-01")
    assert Enum.all?(again, &(match?({:unchanged, _}, &1.result) or &1.result == :not_screened))
  end

  test "an open screening is advanced, or refused if the target is behind it", %{admin: admin} do
    assert {:ok, [%{result: {:ok, a}}]} =
             Batch.run(admin, "MRKU1111111 report_draft", lane: "RPM-T-01")

    assert {:ok, [%{result: {:ok, b}}]} =
             Batch.run(admin, "MRKU1111111 cleared", lane: "RPM-T-01")

    assert a.id == b.id and b.stage == "cleared"

    Batch.run(admin, "MRKU2222222 report_check", lane: "RPM-T-01")

    assert {:ok, [%{result: {:error, {:open_at, "report_check"}}}]} =
             Batch.run(admin, "MRKU2222222 alarm", lane: "RPM-T-01")
  end

  test "needs a super admin and a clean request", %{admin: admin, supervisor: sup} do
    assert {:error, :needs_super_admin} = Batch.run(sup, "MRKU9937602 cleared")
    assert {:error, {:unrecognised, ["nonsense"]}} = Batch.run(admin, "MRKU9937602 nonsense")
    assert {:error, :no_containers} = Batch.run(admin, "  ")
  end
end
