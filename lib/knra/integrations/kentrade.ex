defmodule Knra.Integrations.KenTrade do
  @moduledoc """
  Client for the KenTrade (KNESWS TFP) PGA Container Enquiry API v1.

      POST https://<base>/TFBSEW/cusLogin/pga/container-enquiry

  Headers: `From: <agency code>` and `Authorization: Basic <sha256_hex("username:password")>`
  (a lower-case hex SHA-256 digest, **not** Base64 basic auth).

  Configuration (`config/runtime.exs`, from environment variables):

      config :knra, Knra.Integrations.KenTrade,
        base_url: "https://…",
        username: "…",
        password: "…",
        agency_code: "KNRA",
        mock: false

  With `mock: true` requests are served in-process by
  `Knra.Integrations.KenTrade.MockPlug`, which follows the same contract.
  Every call, including failures, is written to the integration log.
  """

  alias Knra.Integrations

  @path "/TFBSEW/cusLogin/pga/container-enquiry"
  @system "kentrade"

  defmodule Result do
    @moduledoc "Parsed enquiry response."
    defstruct [
      :status,
      :http_status,
      :message,
      :container_number,
      :generated_at,
      warnings: [],
      movements: []
    ]
  end

  @doc """
  Looks up a container. Options: `:reference_number`, `:location_code`,
  `:officer_id`, `:event_datetime` (DateTime), `:filters` (map with the API's
  filter keys).

  Returns `{:ok, %Result{status: "FOUND" | "TRANSIT" | "NOT_FOUND"}}` or
  `{:error, %Result{status: "INVALID_REQUEST" | "UNAUTHORIZED" | "ERROR"}}`.
  """
  def container_enquiry(container_number, opts \\ []) do
    body = build_body(container_number, opts)
    started = System.monotonic_time(:millisecond)

    result =
      case Req.post(req(), json: body) do
        {:ok, %Req.Response{status: status, body: resp}} -> parse(status, resp)
        {:error, exception} -> transport_error(exception)
      end

    Integrations.record(%{
      system: @system,
      operation: "container_enquiry",
      object_ref: body["containerNumber"],
      request: body,
      response: result_to_log(result),
      http_status: result.http_status,
      outcome: String.downcase(result.status),
      duration_ms: System.monotonic_time(:millisecond) - started
    })

    if result.status in ~w(FOUND TRANSIT NOT_FOUND), do: {:ok, result}, else: {:error, result}
  end

  @doc "The `Authorization` header value for the configured credentials."
  def authorization(username, password) do
    "Basic " <> (:crypto.hash(:sha256, "#{username}:#{password}") |> Base.encode16(case: :lower))
  end

  @doc "Normalises a container number the way TFP does: upper case, no spaces or hyphens."
  def normalise(number),
    do: number |> to_string() |> String.upcase() |> String.replace(~r/[\s\-]/, "")

  def config, do: Application.get_env(:knra, __MODULE__, [])

  defp req do
    cfg = config()

    base =
      Req.new(
        base_url: cfg[:base_url] || "https://kentrade.invalid",
        url: @path,
        headers: [
          {"from", cfg[:agency_code] || ""},
          {"authorization", authorization(cfg[:username], cfg[:password])}
        ],
        receive_timeout: cfg[:receive_timeout] || 10_000,
        retry: :transient,
        max_retries: cfg[:max_retries] || 2,
        retry_log_level: :warning
      )

    cond do
      cfg[:plug] -> Req.merge(base, plug: cfg[:plug], retry: false)
      cfg[:mock] -> Req.merge(base, plug: Knra.Integrations.KenTrade.MockPlug, retry: false)
      true -> base
    end
  end

  defp build_body(container_number, opts) do
    %{"containerNumber" => normalise(container_number)}
    |> put_opt("referenceNumber", opts[:reference_number])
    |> put_opt("locationCode", opts[:location_code])
    |> put_opt("officerId", opts[:officer_id])
    |> put_opt(
      "eventDateTime",
      opts[:event_datetime] && Knra.Time.iso_local(opts[:event_datetime])
    )
    |> put_opt("filters", opts[:filters])
  end

  defp put_opt(map, _k, v) when v in [nil, "", %{}], do: map
  defp put_opt(map, k, v), do: Map.put(map, k, v)

  defp parse(http_status, body) when is_map(body) do
    %Result{
      http_status: http_status,
      status: body["status"] || status_for(http_status),
      message: body["message"],
      container_number: body["containerNumber"],
      generated_at: body["generatedAt"],
      warnings: List.wrap(body["warnings"]),
      movements: List.wrap(body["movements"])
    }
  end

  # A non-JSON 403 comes from KenTrade's gateway/SSO layer, before the API checks
  # credentials — typically the caller's IP is not allow-listed.
  defp parse(403, _body) do
    %Result{
      http_status: 403,
      status: "FORBIDDEN",
      message:
        "KenTrade gateway refused access (HTTP 403) before checking credentials — check IP allow-listing and API access for this account."
    }
  end

  defp parse(http_status, body) do
    %Result{
      http_status: http_status,
      status: status_for(http_status),
      message: "Unexpected response from KenTrade: #{String.slice(to_string(body), 0, 200)}"
    }
  end

  defp status_for(200), do: "FOUND"
  defp status_for(400), do: "INVALID_REQUEST"
  defp status_for(401), do: "UNAUTHORIZED"
  defp status_for(404), do: "NOT_FOUND"
  defp status_for(_), do: "ERROR"

  defp transport_error(exception) do
    %Result{status: "ERROR", message: "KenTrade unreachable: #{Exception.message(exception)}"}
  end

  defp result_to_log(%Result{} = r),
    do: r |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end)
end
