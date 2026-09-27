defmodule Knra.Integrations.KenTrade.MockPlug do
  @moduledoc """
  In-process stand-in for the KenTrade PGA Container Enquiry API, used in
  development and demos (`mock: true`). It follows the v1 contract: checks the
  `From` and SHA-256 `Authorization` headers, validates the body and returns
  FOUND / TRANSIT / NOT_FOUND / INVALID_REQUEST / UNAUTHORIZED bodies.

  Containers in `catalogue/0` are FOUND; `TRANSIT_CONTAINERS` answer TRANSIT;
  anything else is NOT_FOUND. Container `ERRU0000000` returns a 500.
  """

  @behaviour Plug
  import Plug.Conn

  alias Knra.Integrations.KenTrade

  @transit ~w(TRLU9001234 MSCU5550001)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    {:ok, raw, conn} = read_body(conn)
    cfg = KenTrade.config()
    expected_auth = KenTrade.authorization(cfg[:username], cfg[:password])

    cond do
      get_req_header(conn, "from") != [cfg[:agency_code] || ""] or
          get_req_header(conn, "authorization") != [expected_auth] ->
        reply(conn, 401, %{status: "UNAUTHORIZED", message: "Authorization has been denied for this request."})

      raw == "" ->
        reply(conn, 400, %{status: "INVALID_REQUEST", message: "Request body is required."})

      true ->
        case Jason.decode(raw) do
          {:ok, %{"containerNumber" => n}} when is_binary(n) and n != "" -> lookup(conn, KenTrade.normalise(n))
          {:ok, _} -> reply(conn, 400, %{status: "INVALID_REQUEST", message: "containerNumber is required."})
          _ -> reply(conn, 400, %{status: "INVALID_REQUEST", message: "Request body must be JSON."})
        end
    end
  end

  defp lookup(conn, number) do
    cond do
      not Regex.match?(~r/^[A-Z]{4}\d{7}$/, number) ->
        reply(conn, 400, %{status: "INVALID_REQUEST", message: "Invalid containerNumber format."})

      number == "ERRU0000000" ->
        reply(conn, 500, %{status: "ERROR", message: "Request could not be processed. Please try again."})

      number in @transit ->
        reply(conn, 200, %{status: "TRANSIT", message: "Container #{number} is known, this is a transit.", containerNumber: number})

      movement = Map.get(catalogue(), number) ->
        reply(conn, 200, %{status: "FOUND", message: "Container details found.", containerNumber: number, movements: [movement]})

      true ->
        since = Date.add(Knra.Time.today(), -60) |> Date.to_iso8601()

        reply(conn, 404, %{
          status: "NOT_FOUND",
          message: "No record of container #{number} arriving on or after #{since}.",
          containerNumber: number
        })
    end
  end

  defp reply(conn, status, body) do
    body = Map.put(body, :generatedAt, Knra.Time.iso_local(Knra.Time.now()))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc "Sample consignments keyed by container number (from the reviewed demo)."
  def catalogue do
    %{
      "MSKU7741293" => movement("2026 1187", "MV NORTHERN JADE", "204E", "40", "GP", "KE7712093", 24_180,
        "MSKUBL2026077412", "UCR2026MSK7741293", "CNSHA", "NAIROBI", 610,
        "RIFT VALLEY MOTORS LTD", "P051118822K", "P.O. BOX 4410-20100 NAKURU", "2026 MSA 204811",
        "GUANGZHOU AUTO PARTS CO LTD", [{"MOTOR VEHICLE BODY PARTS", "87082900"}]),
      "TGHU5029184" => movement("2026 1175", "MV KILINDINI STAR", "088W", "20", "GP", "KE7713310", 27_600,
        "TGHUBL2026050291", "UCR2026TGH5029184", "INNSA", "MOMBASA", 42,
        "COAST STEEL MILLS LTD", "P051203394M", "P.O. BOX 90210-80100 MOMBASA", "2026 MSA 204377",
        "JSW STEEL LTD", [{"HOT-ROLLED STEEL PLATE", "72085100"}]),
      "CMAU1187640" => movement("2026 1169", "MV INDIAN OCEAN", "311E", "20", "GP", "KE7709921", 28_900,
        "CMAUBL2026011876", "UCR2026CMA1187640", "PKKHI", "ATHI RIVER", 560,
        "ATHI CEMENT EA LTD", "P051338812Q", "P.O. BOX 55-00204 ATHI RIVER", "2026 MSA 203990",
        "LUCKY CEMENT LTD", [{"PORTLAND CEMENT CLINKER", "25232900"}]),
      "MRKU8891004" => movement("2026 1169", "MV INDIAN OCEAN", "311E", "40", "GP", "KE7710455", 26_300,
        "MRKUBL2026088910", "UCR2026MRK8891004", "PKKHI", "MOMBASA", 1040,
        "MOMBASA GRAIN TRADERS LTD", "P051422871A", "P.O. BOX 81233-80100 MOMBASA", "2026 MSA 204502",
        "KARACHI RICE EXPORTS", [{"SEMI-MILLED RICE", "10063000"}]),
      "OOLU4471228" => movement("2026 1175", "MV KILINDINI STAR", "088W", "40", "HC", "KE7713871", 19_880,
        "OOLUBL2026044712", "UCR2026OOL4471228", "AEJEA", "NAIROBI", 820,
        "SILPACK INDUSTRIES LTD", "P051501234C", "P.O. BOX 18011-00500 NAIROBI", "2026 MSA 204655",
        "GULF POLYMERS FZE", [{"POLYETHYLENE PACKAGING FILM", "39232900"}]),
      "HLXU2288119" => movement("2026 1187", "MV NORTHERN JADE", "204E", "40", "GP", "KE7712540", 21_450,
        "HLXUBL2026022881", "UCR2026HLX2288119", "CNSHA", "NAIROBI", 390,
        "SOLLATEK EAST AFRICA LTD", "P051099871D", "P.O. BOX 47340-00100 NAIROBI", "2026 MSA 204890",
        "NINGBO CABLE WORKS", [{"INSULATED ELECTRICAL CABLE", "85444900"}]),
      "PONU3345671" => movement("2026 1175", "MV KILINDINI STAR", "088W", "20", "OT", "KE7713002", 29_120,
        "PONUBL2026033456", "UCR2026PON3345671", "AEJEA", "MOMBASA", 1,
        "NYALI METALS LTD", "P051677120E", "P.O. BOX 99-80109 MTWAPA", "2026 MSA 204301",
        "EMIRATES SCRAP TRADING LLC", [{"FERROUS SCRAP METAL", "72044900"}]),
      "MSKU9930211" => movement("2026 1187", "MV NORTHERN JADE", "204E", "40", "GP", "KE7712888", 22_040,
        "MSKUBL2026099302", "UCR2026MSK9930211", "CNSHA", "NAIROBI", 1850,
        "BATA SHOE COMPANY (KENYA) LTD", "P000601234B", "P.O. BOX 23-00217 LIMURU", "2026 MSA 204790",
        "DONGGUAN FOOTWEAR CO", [{"FOOTWEAR, LEATHER UPPERS", "64039900"}])
    }
  end

  @doc "Container numbers the mock answers with TRANSIT."
  def transit_containers, do: @transit

  defp movement(manifest, vessel, voyage, size, type, seal, weight, bl, ucr, pol, delivery, packages,
         importer, pin, address, declaration, consignor, goods) do
    %{
      transportMode: "SEA",
      vesselCall: %{
        manifestNumber: manifest,
        rotationNumber: String.replace(manifest, " ", "/"),
        shippingAgent: "EXAMPLE SHIPPING AGENCIES LTD",
        vesselNumber: vessel,
        voyageNumber: voyage,
        portOfDischarge: "KEMBA",
        estimatedArrival: Knra.Time.iso_local(DateTime.add(Knra.Time.now(), -3 * 86_400, :second))
      },
      container: %{size: size, type: type, sealNumber: seal, loadStatus: "3", grossWeightKg: weight},
      consignments: [
        %{
          billOfLadingNumber: bl,
          blLevel: "MASTER",
          consolidated: false,
          ucrNumber: ucr,
          portOfLoading: pol,
          placeOfDelivery: delivery,
          countryOfDestination: "KE",
          packages: packages,
          grossWeightKg: weight,
          importer: %{name: importer, pin: pin, address: address, source: "DECLARATION", declarationNumber: declaration},
          consignor: %{name: consignor, address: "—", source: "DECLARATION"},
          goods: Enum.map(goods, fn {d, hs} -> %{description: d, hsCode: hs} end)
        }
      ]
    }
  end
end
