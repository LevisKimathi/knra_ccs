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
    # "rpm_feed" (RPM / simulator event) or "manual" (recorded by an RPM operator)
    field :source, :string, default: "rpm_feed"
    field :evidence_photos, {:array, :string}, default: []
    # Recorded without KenTrade confirmation: the operator's reason, and the
    # supervisor review (nil = not flagged, "pending", "reviewed")
    field :override_reason, :string
    field :review_status, :string
    field :reviewed_at, :utc_datetime
    field :review_note, :string

    field :lookup_status, :string, default: "pending"
    field :lookup_message, :string
    field :lookup_at, :utc_datetime
    field :consignment, :map, default: %{}
    field :importer_name, :string
    field :goods_description, :string
    field :hs_code, :string
    field :ucr_number, :string
    # Which arrival this screening belongs to (containers are reused across voyages)
    field :manifest_number, :string
    field :arrived_at, :utc_datetime
    field :consignment_refs, {:array, :string}, default: []

    field :certificate_number, :string
    field :cleared_at, :utc_datetime

    belongs_to :lane, Knra.Devices.Lane
    belongs_to :recorded_by, Knra.Accounts.User
    belongs_to :reviewed_by, Knra.Accounts.User
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

  @doc "Normalises a manifest / B/L / UCR for matching: upper case, no spaces or hyphens."
  def normalise_ref(nil), do: nil

  def normalise_ref(ref),
    do: ref |> to_string() |> String.upcase() |> String.replace(~r/[\s\-]/, "")

  def current_report(%__MODULE__{reports: [r | _]}), do: r
  def current_report(_), do: nil
end
