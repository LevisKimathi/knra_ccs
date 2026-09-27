# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :knra, :scopes,
  user: [
    default: true,
    module: Knra.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Knra.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :knra,
  ecto_repos: [Knra.Repo],
  generators: [timestamp_type: :utc_datetime]

# ---- KNRA CCS application settings
config :knra,
  # RPM and M-Pesa simulators (enabled in dev only; see dev.exs)
  simulators_enabled: false,
  # Look up KenTrade in a background task after an RPM pass
  async_lookup: true,
  # Alarms waiting longer than this are highlighted in the alarm queue
  alarm_sla_minutes: 15,
  # Where field-inspection photos are stored
  uploads_dir: Path.expand("../uploads", __DIR__),
  mail_from: {"KNRA Cargo Screening", "no-reply@knra.go.ke"}

# KenTrade PGA Container Enquiry API. Credentials are read from the
# environment in config/runtime.exs.
config :knra, Knra.Integrations.KenTrade,
  base_url: nil,
  username: nil,
  password: nil,
  agency_code: nil,
  mock: false,
  receive_timeout: 10_000,
  max_retries: 2

# Configure the endpoint
config :knra, KnraWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KnraWeb.ErrorHTML, json: KnraWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Knra.PubSub,
  live_view: [signing_salt: "ogMEAIIc"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :knra, Knra.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  knra: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  knra: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
