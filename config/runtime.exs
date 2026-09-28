import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/knra start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :knra, KnraWeb.Endpoint, server: true
end

config :knra, KnraWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ---- KenTrade PGA Container Enquiry API
# KENTRADE_BASE_URL   e.g. https://<trial or production host issued by KenTrade>
# KENTRADE_USERNAME / KENTRADE_PASSWORD  (sent as sha256_hex("username:password"))
# KENTRADE_AGENCY_CODE  sent in the From header
# KENTRADE_MOCK=true   serve lookups from the built-in mock instead
if config_env() != :test do
  kentrade = Application.get_env(:knra, Knra.Integrations.KenTrade, [])

  mock? =
    case System.get_env("KENTRADE_MOCK") do
      nil -> kentrade[:mock]
      v -> v in ~w(true 1 yes)
    end

  config :knra, Knra.Integrations.KenTrade,
    base_url: System.get_env("KENTRADE_BASE_URL", kentrade[:base_url]),
    username: System.get_env("KENTRADE_USERNAME", kentrade[:username]),
    password: System.get_env("KENTRADE_PASSWORD", kentrade[:password]),
    agency_code: System.get_env("KENTRADE_AGENCY_CODE", kentrade[:agency_code]),
    mock: mock?

  # ---- Container status API: clients and credentials are managed in the app
  # (Administration → API clients); only the query window is configured here.
  if days = System.get_env("STATUS_WINDOW_DAYS") do
    config :knra, status_window_days: String.to_integer(days)
  end

  if v = System.get_env("SIMULATORS_ENABLED") do
    config :knra, simulators_enabled: v in ~w(true 1 yes)
  end

  if dir = System.get_env("UPLOADS_DIRECTORY") do
    config :knra, uploads_dir: dir
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :knra, Knra.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  # Serve under a sub-path behind nginx (e.g. PHX_PATH="/knra" for
  # https://linktivity.dev/knra/). nginx strips the prefix; generated links,
  # assets, emailed URLs and the LiveView socket get it added back.
  path = System.get_env("PHX_PATH") || "/"

  config :knra, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :knra, KnraWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https", path: path],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :knra, KnraWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :knra, KnraWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ---- Email (login links for staff, detention / device-fault alerts)
  # Staff log in with emailed links, so production needs a real mail server.
  if smtp_host = System.get_env("SMTP_HOST") do
    config :knra, Knra.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: String.to_integer(System.get_env("SMTP_PORT", "587")),
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      tls: :always,
      auth: if(System.get_env("SMTP_USERNAME"), do: :always, else: :never),
      tls_options: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(smtp_host),
        depth: 99
      ]
  else
    # No mail server configured: write emails (including login links) to the
    # service log instead of failing. Read them with `journalctl -u knra`.
    config :knra, Knra.Mailer,
      adapter: Swoosh.Adapters.Logger,
      level: :warning,
      log_full_email: true
  end

  if from = System.get_env("MAIL_FROM") do
    config :knra, mail_from: {"KNRA Cargo Screening", from}
  end

  # Behind a reverse proxy the public URL (used in emailed links) is https on 443
  # while the app itself listens on PORT on localhost.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :knra, Knra.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
