defmodule Knra.Screening.Inspection do
  use Ecto.Schema
  import Ecto.Changeset

  @isotopes [
    "K-40 (NORM)",
    "Ra-226 (NORM)",
    "Th-232 (NORM)",
    "Cs-137",
    "Co-60",
    "Am-241",
    "I-131 (medical)",
    "Tc-99m (medical)",
    "None identified"
  ]

  @outcomes ~w(no_objection detain)

  schema "inspections" do
    field :isotope, :string
    field :dose_rate_usv_h, :decimal
    field :findings, :string
    field :outcome, :string
    field :photos, {:array, :string}, default: []

    belongs_to :application, Knra.Screening.Application
    belongs_to :user, Knra.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def isotopes, do: @isotopes

  def outcome_label("no_objection"), do: "Inspection complete — no objection"
  def outcome_label("detain"), do: "Detention recommended"

  def changeset(insp, attrs) do
    insp
    |> cast(attrs, [:isotope, :dose_rate_usv_h, :findings, :outcome])
    |> update_change(:findings, &String.trim/1)
    |> validate_required([:isotope, :dose_rate_usv_h, :findings, :outcome],
      message: "is required"
    )
    |> validate_inclusion(:isotope, @isotopes)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:dose_rate_usv_h, greater_than_or_equal_to: 0, less_than: 100_000)
    |> validate_length(:findings,
      min: 10,
      message: "must describe what was inspected (at least 10 characters)"
    )
    |> unique_constraint(:application_id)
  end
end
