defmodule KnraWeb.Plugs.ApiClientAuth do
  @moduledoc """
  Authenticates KenTrade's calls to our API with the same scheme KenTrade uses for
  its own PGA API: a `From` header with the client code, and
  `Authorization: Basic <sha256_hex("username:password")>`.

  Credentials come from `config :knra, :status_api` (see `config/runtime.exs`).
  When no password is configured every request is refused.
  """
  @behaviour Plug
  import Plug.Conn

  alias Knra.Integrations.KenTrade

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cfg = Application.get_env(:knra, :status_api, [])
    from = List.first(get_req_header(conn, "from")) || ""
    auth = List.first(get_req_header(conn, "authorization")) || ""

    if cfg[:password] not in [nil, ""] and
         Plug.Crypto.secure_compare(from, cfg[:from] || "") and
         Plug.Crypto.secure_compare(auth, KenTrade.authorization(cfg[:username], cfg[:password])) do
      assign(conn, :api_client, cfg[:from])
    else
      Knra.Integrations.record(%{
        system: "kentrade_inbound",
        operation: "container_status",
        object_ref: from,
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
