defmodule Knra.Screening.Application do
  use Ecto.Schema

  @stages ~w(alarm secondary report_draft report_check approved cleared detained)

  schema "applications" do
    field :reference, :string
    field :container_number, :string
    field :stage, :string

    field :occupancy_ref, :string
    field :scanned_at, :utc_datetime
    field :gamma_cps, :integer
    field :neutron_cps, :integer
    field :alarmed, :boolean, default: false

    field :lookup_status, :string, default: "pending"
    field :lookup_message, :string
    field :lookup_at, :utc_datetime
    field :consignment, :map, default: %{}
    field :importer_name, :string
    field :goods_description, :string
    field :hs_code, :string
    field :ucr_number, :string

    field :certificate_number, :string
    field :cleared_at, :utc_datetime

    belongs_to :lane, Knra.Devices.Lane
    has_one :invoice, Knra.Billing.Invoice
    has_one :adjudication, Knra.Screening.Adjudication
    has_one :inspection, Knra.Screening.Inspection
    has_many :reports, Knra.Screening.Report, preload_order: [desc: :id]

    timestamps(type: :utc_datetime)
  end

  def stages, do: @stages

  @labels %{
    "alarm" => "Alarm — awaiting adjudication",
    "secondary" => "Secondary inspection",
    "report_draft" => "Awaiting screening report",
    "report_check" => "Awaiting verification",
    "approved" => "Approved — awaiting payment",
    "cleared" => "Cleared",
    "detained" => "Detained"
  }

  def stage_label(stage), do: Map.get(@labels, stage, stage)

  @doc "Display container number as `MSKU 7741293`."
  def display_container(<<prefix::binary-4, rest::binary>>), do: prefix <> " " <> rest
  def display_container(other), do: other

  def current_report(%__MODULE__{reports: [r | _]}), do: r
  def current_report(_), do: nil
end
