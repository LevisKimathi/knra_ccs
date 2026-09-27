defmodule KnraWeb.Api.ContainerStatusController do
  @moduledoc """
  `POST /api/kentrade/container-status` — KenTrade asks for the KNRA screening
  status of up to 100 containers at once.

  Request: `[{"containerNumber": "MSKU7741293", "manifestNumber": "2026 1187"}, ...]`
  (`manifestNumber`, `billOfLadingNumber` and `ucrNumber` are optional and pin the
  answer to one arrival). Response: one entry per request item, in order. See
  `Knra.Screening.StatusQuery`.
  """
  use KnraWeb, :controller

  alias Knra.Integrations
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

      Integrations.record(%{
        system: "kentrade_inbound",
        operation: "container_status",
        object_ref: items |> Enum.map_join(", ", &item_ref/1) |> String.slice(0, 250),
        request: %{"items" => items},
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
    Integrations.record(%{
      system: "kentrade_inbound",
      operation: "container_status",
      request: %{"body" => request},
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

  defp item_ref(%{"containerNumber" => c}), do: to_string(c)
  defp item_ref(_), do: "?"
end
