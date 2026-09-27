defmodule Knra.Billing.FeeSchedule do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending_approval approved rejected)

  schema "fee_schedules" do
    field :version, :integer
    field :effective_from, :date
    field :status, :string, default: "pending_approval"
    field :note, :string
    field :approved_at, :utc_datetime
    field :rejection_reason, :string

    belongs_to :created_by, Knra.Accounts.User
    belongs_to :approved_by, Knra.Accounts.User
    has_many :items, Knra.Billing.FeeItem, preload_order: [asc: :position], on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def proposal_changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:effective_from, :note])
    |> validate_required([:effective_from, :note])
    |> validate_change(:effective_from, fn :effective_from, d ->
      if Date.compare(d, Knra.Time.today()) == :lt,
        do: [effective_from: "cannot be in the past"],
        else: []
    end)
    |> cast_assoc(:items, with: &Knra.Billing.FeeItem.changeset/2, required: true)
  end
end
