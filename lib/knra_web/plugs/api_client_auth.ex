defmodule KnraWeb.Plugs.ApiClientAuth do
  @moduledoc """
  Authenticates calls to the container status API from the `Authorization`
  header alone: `Basic <sha256_hex("username:password")>`. The token identifies
  the API client, so no client code header is needed.

  Every refused call is written to the audit trail with the caller's IP and user
  agent (see `Knra.ApiClients.audit_rejected/2`).
  """
  @behaviour Plug
  import Plug.Conn

  alias Knra.ApiClients

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    caller = caller(conn)
    conn = assign(conn, :api_caller, caller)

    case ApiClients.authenticate(List.first(get_req_header(conn, "authorization"))) do
      {:ok, client} ->
        ApiClients.touch(client, caller.ip)
        assign(conn, :api_client, client)

      refused ->
        ApiClients.audit_rejected(refused, caller)

        Knra.Integrations.record(%{
          system: "status_api",
          operation: "container_status",
          object_ref: refused_ref(refused),
          request: %{"ip" => caller.ip, "user_agent" => caller.user_agent},
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

  @doc """
  The caller's IP and user agent. Behind nginx every request comes from the
  loopback address, so the proxy's `X-Real-IP` / `X-Forwarded-For` is used, but
  only then: a caller reaching the app directly cannot spoof its address.
  """
  def caller(conn) do
    %{
      ip: client_ip(conn),
      user_agent: conn |> get_req_header("user-agent") |> List.first() |> truncate()
    }
  end

  defp client_ip(%{remote_ip: remote} = conn) do
    direct = remote |> :inet.ntoa() |> to_string()

    if loopback?(remote) do
      forwarded =
        List.first(get_req_header(conn, "x-real-ip")) ||
          conn |> get_req_header("x-forwarded-for") |> List.first() |> first_hop()

      forwarded || direct
    else
      direct
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65535, 32512, _}), do: true
  defp loopback?(_), do: false

  defp first_hop(nil), do: nil
  defp first_hop(xff), do: xff |> String.split(",") |> List.first() |> String.trim()

  defp truncate(nil), do: nil
  defp truncate(ua), do: String.slice(ua, 0, 200)

  defp refused_ref({:revoked, client}), do: "revoked: #{client.client_code}"
  defp refused_ref({:unknown, nil}), do: "no credentials"
  defp refused_ref({:unknown, fp}), do: "unknown token #{fp}"
end
