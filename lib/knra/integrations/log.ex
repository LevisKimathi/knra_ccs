defmodule Knra.Integrations.Log do
  use Ecto.Schema

  schema "integration_logs" do
    field :system, :string
    field :operation, :string
    field :object_ref, :string
    field :request, :map, default: %{}
    field :response, :map, default: %{}
    field :http_status, :integer
    field :outcome, :string
    field :duration_ms, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
