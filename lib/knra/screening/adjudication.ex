defmodule Knra.Screening.Adjudication do
  use Ecto.Schema
  import Ecto.Changeset

  @classifications [
    "NORM (naturally occurring)",
    "Medical isotope",
    "Declared industrial source",
    "Background fluctuation",
    "Unresolved — requires secondary",
    "Suspected threat material"
  ]

  @decisions ~w(release secondary detain)

  schema "adjudications" do
    field :decision, :string
    field :classification, :string
    field :reason, :string

    belongs_to :application, Knra.Screening.Application
    belongs_to :user, Knra.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def classifications, do: @classifications
  def decisions, do: @decisions

  def decision_label("release"), do: "Released — no radiological objection"
  def decision_label("secondary"), do: "Diverted to secondary inspection"
  def decision_label("detain"), do: "Detained & escalated"

  def changeset(adj, attrs) do
    adj
    |> cast(attrs, [:decision, :classification, :reason])
    |> update_change(:reason, &String.trim/1)
    |> validate_required([:decision, :classification, :reason], message: "is required")
    |> validate_inclusion(:decision, @decisions)
    |> validate_inclusion(:classification, @classifications)
    |> validate_length(:reason,
      min: 10,
      message: "must explain the decision (at least 10 characters)"
    )
    |> unique_constraint(:application_id)
  end
end
