defmodule Knra.Repo do
  use Ecto.Repo,
    otp_app: :knra,
    adapter: Ecto.Adapters.Postgres
end
