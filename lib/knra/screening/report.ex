defmodule Knra.Screening.Report do
  use Ecto.Schema
  import Ecto.Changeset

  schema "reports" do
    # submitted -> approved | rejected
    field :status, :string, default: "submitted"
    field :result, :string
    field :narrative, :string
    field :submitted_at, :utc_datetime
    field :decided_at, :utc_datetime
    field :rejection_reason, :string

    belongs_to :application, Knra.Screening.Application
    belongs_to :maker, Knra.Accounts.User
    belongs_to :checker, Knra.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def narrative_changeset(report, attrs) do
    report
    |> cast(attrs, [:narrative])
    |> update_change(:narrative, &String.trim/1)
    |> validate_required([:narrative], message: "is required")
    |> validate_length(:narrative,
      min: 10,
      message: "must describe the screening (at least 10 characters)"
    )
  end

  def rejection_changeset(report, attrs) do
    report
    |> cast(attrs, [:rejection_reason])
    |> update_change(:rejection_reason, &String.trim/1)
    |> validate_required([:rejection_reason], message: "is required to reject a report")
  end
end
