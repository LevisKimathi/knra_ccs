defmodule Knra.UnansweredQueriesTest do
  use KnraWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Knra.ScreeningFixtures

  alias Knra.Simulator.Batch
  alias Knra.Accounts.Scope

  setup ctx do
    ctx = Map.merge(ctx, setup_screening())

    admin =
      Scope.for_user(Knra.AccountsFixtures.user_fixture(%{role: "super_admin", name: "Root"}))

    {:ok, _, _} =
      Knra.ApiClients.create_client(
        admin,
        %{
          "name" => "Kenya Trade Network Agency",
          "client_code" => "KENTRADE",
          "username" => "kentrade-test"
        },
        "test-status-password"
      )

    Map.put(ctx, :super_admin, admin)
  end

  # KenTrade asking our status API
  defp kentrade_asks(containers) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "authorization",
      "Basic " <> Knra.ApiClients.token("kentrade-test", "test-status-password")
    )
    |> post(
      "/api/container-status",
      Jason.encode!(Enum.map(containers, &%{"containerNumber" => &1}))
    )
    |> json_response(200)
  end

  test "finds containers answered NOT_FOUND that are still unscreened" do
    rpm_pass("TGHU5029184")
    kentrade_asks(["MSKU7741293", "msku 774-1293", "ABCU1234560", "TGHU5029184", "X20260902501"])

    {containers, invalid} = Batch.unanswered(7)

    assert Enum.map(containers, & &1.container) |> Enum.sort() == ["ABCU1234560", "MSKU7741293"]

    assert %{asked: 2, clients: ["KENTRADE"]} =
             Enum.find(containers, &(&1.container == "MSKU7741293"))

    assert invalid == ["X20260902501"]
  end

  test "looks each up in KenTrade, stores the consignment and clears it", ctx do
    kentrade_asks(["MSKU7741293", "ABCU1234560"])
    {containers, _} = Batch.unanswered(7)

    {:ok, results} = Batch.clear_unanswered(ctx.super_admin, Enum.map(containers, & &1.container))

    found = Enum.find(results, &(&1.container == "MSKU7741293"))
    assert found.kentrade == "FOUND"
    assert {:ok, app} = found.result
    app = reload(app)
    assert app.stage == "cleared"
    assert app.certificate_number
    assert app.lookup_status == "found"
    assert app.importer_name == "RIFT VALLEY MOTORS LTD"
    assert found.api["status"] == "CLEARED"

    unknown = Enum.find(results, &(&1.container == "ABCU1234560"))
    assert unknown.kentrade == "NOT_FOUND"
    assert {:ok, _} = unknown.result
    assert unknown.api["status"] == "CLEARED"

    # KenTrade now gets CLEARED, and nothing is left to clear
    assert [%{"status" => "CLEARED"}, %{"status" => "CLEARED"}] =
             kentrade_asks(["MSKU7741293", "ABCU1234560"])

    assert {[], []} = Batch.unanswered(7)
  end

  test "needs a super admin", ctx do
    assert {:error, :needs_super_admin} = Batch.clear_unanswered(ctx.supervisor, ["MSKU7741293"])
  end

  test "Simulator screen lists and clears them", ctx do
    kentrade_asks(["MSKU7741293"])

    {:ok, lv, html} = live(log_in_user(ctx.conn, ctx.super_admin.user), ~p"/simulator")
    assert html =~ "Containers Answered Not Found"
    assert has_element?(lv, "#unanswered-card", "MSKU 7741293")

    lv |> element("#clear-unanswered") |> render_click()
    assert has_element?(lv, "#unanswered-results", "CLEARED")
    assert has_element?(lv, "#unanswered-results .bg-ok-soft", "FOUND")
    assert render(lv) =~ "No unanswered containers in this period"
  end
end
