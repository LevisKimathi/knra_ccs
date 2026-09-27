defmodule Knra.Billing.Invoice do
  use Ecto.Schema

  schema "invoices" do
    field :number, :string
    field :description, :string
    field :amount_usd, :decimal
    field :amount_kes, :decimal
    field :status, :string, default: "pending"
    field :paid_at, :utc_datetime

    belongs_to :application, Knra.Screening.Application
    belongs_to :fee_schedule, Knra.Billing.FeeSchedule
    has_many :payments, Knra.Billing.Payment, preload_order: [asc: :received_at]

    timestamps(type: :utc_datetime)
  end

  def paid?(%__MODULE__{status: "paid"}), do: true
  def paid?(_), do: false

  def amount_received(%__MODULE__{payments: payments}) when is_list(payments) do
    payments
    |> Enum.filter(&(&1.status == "matched"))
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.amount_kes))
  end

  def balance(%__MODULE__{} = inv) do
    Decimal.max(Decimal.sub(inv.amount_kes, amount_received(inv)), Decimal.new(0))
  end
end
