defmodule KnraWeb.Api.ContainerStatusController do
  @moduledoc """
  `POST /api/container-status` — a registered API client (KenTrade, a shipping
  line, a terminal operator, ...) asks for the KNRA screening status of up to 100
  containers at once. Authentication: `KnraWeb.Plugs.ApiClientAuth`.

  Request: `[{"containerNumber": "MSKU7741293", "manifestNumber": "2026 1187"}, ...]`
  (`manifestNumber`, `billOfLadingNumber` and `ucrNumber` are optional and pin the
  answer to one arrival). Response: one entry per request item, in order. See
  `Knra.Screening.StatusQuery`.
  """
  use KnraWeb, :controller

  alias Knra.{ApiClients, Integrations}
  alias Knra.Screening.StatusQuery

  def create(conn, %{"_json" => items}) when is_list(items) and items != [] do
    started = System.monotonic_time(:millisecond)

    if length(items) > StatusQuery.max_items() do
      error(
        conn,
        400,
        "At most #{StatusQuery.max_items()} containers can be queried per request.",
        items
      )
    else
      results = StatusQuery.lookup(items)
      client = conn.assigns.api_client
      containers = items |> Enum.map_join(", ", &item_ref/1) |> String.slice(0, 250)

      ApiClients.audit_call(
        client,
        conn.assigns.api_caller,
        "Container status queried — #{length(items)} container(s): #{summary(results)}",
        "containers: #{containers}"
      )

      Integrations.record(%{
        system: "status_api",
        operation: "container_status",
        object_ref: containers,
        request: request_log(conn, %{"items" => items}),
        response: %{"items" => results},
        http_status: 200,
        outcome: "ok",
        duration_ms: System.monotonic_time(:millisecond) - started
      })

      json(conn, results)
    end
  end

  def create(conn, params) do
    error(
      conn,
      400,
      "Request body must be a non-empty JSON array of {\"containerNumber\": ...} objects.",
      params
    )
  end

  defp error(conn, status, message, request) do
    ApiClients.audit_call(
      conn.assigns.api_client,
      conn.assigns.api_caller,
      "Invalid container status request (HTTP #{status})",
      message
    )

    Integrations.record(%{
      system: "status_api",
      operation: "container_status",
      request: request_log(conn, %{"body" => request}),
      response: %{"status" => "INVALID_REQUEST", "message" => message},
      http_status: status,
      outcome: "invalid_request",
      duration_ms: 0
    })

    conn
    |> put_status(status)
    |> json(%{
      status: "INVALID_REQUEST",
      message: message,
      generatedAt: Knra.Time.iso_local(Knra.Time.now())
    })
  end

  defp request_log(conn, extra) do
    client = conn.assigns.api_client
    caller = conn.assigns.api_caller

    Map.merge(
      %{
        "client" => client.client_code,
        "username" => client.username,
        "ip" => caller.ip,
        "user_agent" => caller.user_agent
      },
      extra
    )
  end

  defp summary(results) do
    results
    |> Enum.frequencies_by(& &1["status"])
    |> Enum.sort()
    |> Enum.map_join(", ", fn {status, n} -> "#{n} #{status}" end)
  end

  defp item_ref(%{"containerNumber" => c}), do: to_string(c)
  defp item_ref(_), do: "?"
end
