defmodule KnraWeb.ContainerStatusApiTest do
  use KnraWeb.ConnCase, async: false

  import Ecto.Query
  import Knra.ScreeningFixtures

  alias Knra.{Repo, Screening}
  alias Knra.Screening.Application

  setup :setup_screening

  @path "/api/kentrade/container-status"

  defp authed(conn) do
    token =
      :crypto.hash(:sha256, "kentrade-test:test-status-password") |> Base.encode16(case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("from", "KENTRADE")
    |> put_req_header("authorization", "Basic " <> token)
  end

  defp query(conn, items),
    do: conn |> authed() |> post(@path, Jason.encode!(items)) |> json_response(200)

  defp clear!(ctx, app) do
    {:ok, _} =
      Screening.submit_report(ctx.checking_officer, app, %{"narrative" => "Clear pass, no alarm."})

    {:ok, _} = Screening.approve_report(ctx.verification_officer, app)
    {:ok, _} = mpesa(app.invoice.number)
    reload(app)
  end

  # Pretend a screening happened `days` ago (a previous voyage)
  defp age!(app, days) do
    at = DateTime.add(Knra.Time.now(), -days * 86_400, :second)
    Repo.update_all(from(a in Application, where: a.id == ^app.id), set: [scanned_at: at])
  end

  test "answers the sample request in order", %{conn: conn} = ctx do
    cleared = clear!(ctx, rpm_pass("MSKU7741293"))

    {:ok, _} =
      Screening.adjudicate(ctx.cas_operator, rpm_pass("PONU3345671", true), %{
        "decision" => "detain",
        "classification" => "Suspected threat material",
        "reason" => "Cs-137 localised in rear third"
      })

    rpm_pass("CMAU1187640", true)

    assert [
             %{"containerNumber" => "PONU3345671", "status" => "DETAINED"},
             %{
               "containerNumber" => "msku-774 1293",
               "status" => "CLEARED",
               "certificateNumber" => cert,
               "matchedBy" => "CONTAINER"
             },
             %{
               "containerNumber" => "CMAU1187640",
               "status" => "IN_PROGRESS",
               "stage" => "ALARM_ADJUDICATION"
             },
             %{"containerNumber" => "X20260902503", "status" => "NOT_FOUND"}
           ] =
             query(conn, [
               %{"containerNumber" => "PONU3345671"},
               %{"containerNumber" => "msku-774 1293"},
               %{"containerNumber" => "CMAU1187640"},
               %{"containerNumber" => "X20260902503"}
             ])

    assert cert == cleared.certificate_number
  end

  test "returns the arrival's identifiers so KenTrade can check it", %{conn: conn} do
    rpm_pass("MSKU7741293")

    assert [
             %{
               "manifestNumber" => "2026 1187",
               "billOfLadingNumbers" => ["MSKUBL2026077412"],
               "ucrNumbers" => ["UCR2026MSK7741293"],
               "screenedAt" => _
             }
           ] =
             query(conn, [%{"containerNumber" => "MSKU7741293"}])
  end

  describe "reused containers" do
    test "an identifier pins the answer to that arrival", %{conn: conn} = ctx do
      old = clear!(ctx, rpm_pass("MSKU7741293"))
      # Same container back on a later voyage: rewrite the old screening's arrival
      Repo.update_all(from(a in Application, where: a.id == ^old.id),
        set: [consignment_refs: ["OLDMANIFEST", "OLDBL"], manifest_number: "OLD MANIFEST"]
      )

      # Asked about the new arrival before it has been scanned → NOT_FOUND, not the old CLEARED
      assert [%{"status" => "NOT_FOUND"}] =
               query(conn, [
                 %{"containerNumber" => "MSKU7741293", "billOfLadingNumber" => "MSKUBL2026077412"}
               ])

      # Asked about the old arrival → its result
      assert [%{"status" => "CLEARED", "matchedBy" => "ARRIVAL"}] =
               query(conn, [
                 %{"containerNumber" => "MSKU7741293", "manifestNumber" => "old-manifest"}
               ])

      # New arrival scanned → its own, in-progress screening
      new = rpm_pass("MSKU7741293")

      assert [
               %{
                 "status" => "IN_PROGRESS",
                 "applicationReference" => ref,
                 "matchedBy" => "ARRIVAL"
               }
             ] =
               query(conn, [
                 %{"containerNumber" => "MSKU7741293", "billOfLadingNumber" => "MSKUBL2026077412"}
               ])

      assert ref == new.reference
    end

    test "without an identifier, screenings outside the window are not reported",
         %{conn: conn} = ctx do
      app = clear!(ctx, rpm_pass("MSKU7741293"))
      age!(app, 90)
      assert [%{"status" => "NOT_FOUND"}] = query(conn, [%{"containerNumber" => "MSKU7741293"}])
    end

    test "a screening whose KenTrade lookup failed is returned flagged CONTAINER_ONLY", %{
      conn: conn
    } do
      rpm_pass("ABCU1234560")

      assert [%{"status" => "IN_PROGRESS", "matchedBy" => "CONTAINER_ONLY"}] =
               query(conn, [%{"containerNumber" => "ABCU1234560", "ucrNumber" => "UCR123"}])
    end

    test "a stale or detained screening does not block a new RPM pass", ctx do
      old = rpm_pass("MSKU7741293")
      age!(old, 90)
      assert %Application{} = rpm_pass("MSKU7741293")

      {:ok, _} =
        Screening.adjudicate(ctx.cas_operator, rpm_pass("PONU3345671", true), %{
          "decision" => "detain",
          "classification" => "Suspected threat material",
          "reason" => "Cs-137 localised in rear third"
        })

      assert %Application{} = rpm_pass("PONU3345671")
    end
  end

  describe "request validation and auth" do
    test "rejects missing or wrong credentials", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("from", "KENTRADE")

      assert %{"status" => "UNAUTHORIZED"} = conn |> post(@path, "[]") |> json_response(401)

      conn = put_req_header(conn, "authorization", "Basic nope")
      assert %{"status" => "UNAUTHORIZED"} = conn |> post(@path, "[]") |> json_response(401)
    end

    test "rejects bodies that are not a non-empty array, and oversized batches", %{conn: conn} do
      assert %{"status" => "INVALID_REQUEST"} =
               conn |> authed() |> post(@path, "{}") |> json_response(400)

      assert %{"status" => "INVALID_REQUEST"} =
               conn |> authed() |> post(@path, "[]") |> json_response(400)

      big = Jason.encode!(for i <- 1..101, do: %{"containerNumber" => "ABCU#{1_000_000 + i}"})

      assert %{"status" => "INVALID_REQUEST"} =
               build_conn() |> authed() |> post(@path, big) |> json_response(400)
    end

    test "flags malformed items without failing the batch", %{conn: conn} do
      assert [%{"status" => "INVALID_REQUEST"}, %{"status" => "NOT_FOUND"}] =
               query(conn, [%{"container" => "x"}, %{"containerNumber" => "ABCU0000001"}])
    end

    test "every call is logged", %{conn: conn} do
      query(conn, [%{"containerNumber" => "ABCU0000001"}])
      assert [%{system: "kentrade_inbound", outcome: "ok"} | _] = Knra.Integrations.list_logs()
    end
  end
end
