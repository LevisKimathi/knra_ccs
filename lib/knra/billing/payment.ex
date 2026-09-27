defmodule Knra.Billing.Payment do
  use Ecto.Schema
  import Ecto.Changeset

  @methods ~w(mpesa bank)

  schema "payments" do
    field :method, :string
    field :reference, :string
    field :account_reference, :string
    field :amount_kes, :decimal
    field :payer, :string
    field :received_at, :utc_datetime
    # matched: applied to an invoice; unmatched: waiting for reconciliation
    field :status, :string
    field :raw, :map, default: %{}

    belongs_to :invoice, Knra.Billing.Invoice
    belongs_to :recorded_by, Knra.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def method_label("mpesa"), do: "M-Pesa"
  def method_label("bank"), do: "Bank transfer"
  def method_label(m), do: m

  @doc "Form changeset for a bank transfer confirmed by staff."
  def bank_changeset(payment, attrs) do
    payment
    |> cast(attrs, [:reference, :amount_kes, :payer])
    |> validate_required([:reference, :amount_kes])
    |> validate_length(:reference, max: 60)
    |> validate_number(:amount_kes, greater_than: 0)
    |> unique_constraint([:method, :reference], message: "has already been recorded")
  end

  @doc "Changeset for an M-Pesa Paybill (C2B) confirmation."
  def mpesa_changeset(payment, attrs) do
    payment
    |> cast(attrs, [:reference, :account_reference, :amount_kes, :payer, :received_at, :raw])
    |> validate_required([:reference, :account_reference, :amount_kes, :received_at])
    |> validate_number(:amount_kes, greater_than: 0)
    |> unique_constraint([:method, :reference], message: "has already been recorded")
  end

  def methods, do: @methods
end
