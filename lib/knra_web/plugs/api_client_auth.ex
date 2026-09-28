defmodule KnraWeb.Plugs.ApiClientAuth do
  @moduledoc """
  Authenticates calls to the container status API against registered API
  clients (`Knra.ApiClients`): `From: <client code>` and
  `Authorization: Basic <sha256_hex("username:password")>`.
  """
  @behaviour Plug
  import Plug.Conn

  alias Knra.ApiClients

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    from = List.first(get_req_header(conn, "from"))
    auth = List.first(get_req_header(conn, "authorization"))

    case ApiClients.authenticate(from, auth) do
      %ApiClients.Client{} = client ->
        ApiClients.touch(client)
        assign(conn, :api_client, client)

      nil ->
        Knra.Integrations.record(%{
          system: "status_api",
          operation: "container_status",
          object_ref: from || "(no From header)",
          request: %{"remote_ip" => conn.remote_ip |> :inet.ntoa() |> to_string()},
          response: %{"status" => "UNAUTHORIZED"},
          http_status: 401,
          outcome: "unauthorized",
          duration_ms: 0
        })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          401,
          Jason.encode!(%{
            status: "UNAUTHORIZED",
            message: "Authorization has been denied for this request.",
            generatedAt: Knra.Time.iso_local(Knra.Time.now())
          })
        )
        |> halt()
    end
  end
end
