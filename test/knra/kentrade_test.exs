defmodule Knra.Integrations.KenTradeTest do
  use Knra.DataCase, async: false

  alias Knra.Integrations.KenTrade

  setup do
    original = Application.get_env(:knra, KenTrade)

    Application.put_env(
      :knra,
      KenTrade,
      Keyword.merge(original, mock: false, plug: {Req.Test, KenTrade})
    )

    on_exit(fn -> Application.put_env(:knra, KenTrade, original) end)
    :ok
  end

  test "sends the agency code and a SHA-256 hex Authorization token with a normalised body" do
    Req.Test.stub(KenTrade, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/TFBSEW/cusLogin/pga/container-enquiry"
      assert Plug.Conn.get_req_header(conn, "from") == ["KNRA"]

      expected =
        "Basic " <>
          (:crypto.hash(:sha256, "knra-test:test-password") |> Base.encode16(case: :lower))

      assert Plug.Conn.get_req_header(conn, "authorization") == [expected]

      assert %{"containerNumber" => "CSQU3054383", "referenceNumber" => "CCS-1"} =
               Jason.decode!(body)

      Req.Test.json(conn, %{
        "status" => "FOUND",
        "message" => "Container details found.",
        "containerNumber" => "CSQU3054383",
        "movements" => [%{"transportMode" => "SEA"}]
      })
    end)

    assert {:ok, %KenTrade.Result{status: "FOUND", movements: [_]}} =
             KenTrade.container_enquiry("csqu-305 4383", reference_number: "CCS-1")

    assert [%{outcome: "found", object_ref: "CSQU3054383"}] = Knra.Integrations.list_logs()
  end

  test "maps error statuses" do
    Req.Test.stub(KenTrade, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "status" => "UNAUTHORIZED",
        "message" => "Authorization has been denied for this request."
      })
    end)

    assert {:error, %KenTrade.Result{status: "UNAUTHORIZED", http_status: 401}} =
             KenTrade.container_enquiry("CSQU3054383")
  end

  test "reports a gateway HTML 403 as FORBIDDEN" do
    Req.Test.stub(KenTrade, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/html")
      |> Plug.Conn.send_resp(403, "<html>Access Denied</html>")
    end)

    assert {:error, %KenTrade.Result{status: "FORBIDDEN", http_status: 403}} =
             KenTrade.container_enquiry("CSQU3054383")

    assert [%{outcome: "forbidden"}] = Knra.Integrations.list_logs()
  end

  test "reports transport failures as ERROR" do
    Req.Test.stub(KenTrade, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %KenTrade.Result{status: "ERROR", message: "KenTrade unreachable" <> _}} =
             KenTrade.container_enquiry("CSQU3054383")
  end
end
