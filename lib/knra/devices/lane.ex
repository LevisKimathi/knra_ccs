defmodule Knra.Devices.Lane do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lanes" do
    field :name, :string
    field :device_code, :string
    field :serial_number, :string
    field :detector_type, :string
    field :terminal, :string
    field :calibration_due_on, :date
    field :in_service, :boolean, default: true
    field :status_reason, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(lane, attrs) do
    lane
    |> cast(attrs, [
      :name,
      :device_code,
      :serial_number,
      :detector_type,
      :terminal,
      :calibration_due_on
    ])
    |> validate_required([:name, :device_code, :serial_number, :detector_type])
    |> unique_constraint(:device_code)
    |> unique_constraint(:name)
  end

  def calibration_overdue?(%__MODULE__{calibration_due_on: nil}), do: false

  def calibration_overdue?(%__MODULE__{calibration_due_on: d}),
    do: Date.compare(d, Knra.Time.today()) == :lt

  def calibration_due_soon?(%__MODULE__{calibration_due_on: nil}), do: false

  def calibration_due_soon?(%__MODULE__{calibration_due_on: d} = lane),
    do: not calibration_overdue?(lane) and Date.diff(d, Knra.Time.today()) <= 30
end
