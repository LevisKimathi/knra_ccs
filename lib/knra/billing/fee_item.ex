defmodule Knra.Billing.FeeItem do
  use Ecto.Schema
  import Ecto.Changeset

  @codes ~w(screening rescreening secondary_inspection certified_copy)

  schema "fee_items" do
    field :code, :string
    field :description, :string
    field :amount_usd, :decimal
    field :amount_kes, :decimal
    field :position, :integer, default: 0

    belongs_to :fee_schedule, Knra.Billing.FeeSchedule
  end

  def codes, do: @codes

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:code, :description, :amount_usd, :amount_kes, :position])
    |> validate_required([:code, :description, :amount_usd, :amount_kes])
    |> validate_inclusion(:code, @codes)
    |> validate_number(:amount_usd, greater_than_or_equal_to: 0)
    |> validate_number(:amount_kes, greater_than_or_equal_to: 0)
  end
end
