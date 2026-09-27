defmodule Knra.Repo.Migrations.CreateScreeningTables do
  use Ecto.Migration

  def change do
    # Document numbering (CCS-2026-000001, INV-2026-000001, KNRA/CCS/2026/000001)
    execute "CREATE SEQUENCE application_number_seq", "DROP SEQUENCE application_number_seq"
    execute "CREATE SEQUENCE invoice_number_seq", "DROP SEQUENCE invoice_number_seq"
    execute "CREATE SEQUENCE certificate_number_seq", "DROP SEQUENCE certificate_number_seq"

    # ---- M8 RPM devices / lanes
    create table(:lanes) do
      add :name, :string, null: false
      add :device_code, :string, null: false
      add :serial_number, :string, null: false
      add :detector_type, :string, null: false
      add :terminal, :string
      add :calibration_due_on, :date
      add :in_service, :boolean, null: false, default: true
      add :status_reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:lanes, [:device_code])
    create unique_index(:lanes, [:name])

    # ---- M9 fee schedules (versioned, approved before effective)
    create table(:fee_schedules) do
      add :version, :integer, null: false
      add :effective_from, :date, null: false
      add :status, :string, null: false, default: "draft"
      add :note, :text
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :approved_by_id, references(:users, on_delete: :nilify_all)
      add :approved_at, :utc_datetime
      add :rejection_reason, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fee_schedules, [:version])

    create table(:fee_items) do
      add :fee_schedule_id, references(:fee_schedules, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :description, :string, null: false
      add :amount_usd, :decimal, precision: 12, scale: 2, null: false
      add :amount_kes, :decimal, precision: 12, scale: 2, null: false
      add :position, :integer, null: false, default: 0
    end

    create unique_index(:fee_items, [:fee_schedule_id, :code])

    # ---- M3 screening applications (one per RPM occupancy)
    create table(:applications) do
      add :reference, :string, null: false
      add :container_number, :string, null: false
      add :stage, :string, null: false

      # RPM occupancy
      add :lane_id, references(:lanes, on_delete: :restrict), null: false
      add :occupancy_ref, :string, null: false
      add :scanned_at, :utc_datetime, null: false
      add :gamma_cps, :integer, null: false
      add :neutron_cps, :integer, null: false
      add :alarmed, :boolean, null: false, default: false

      # KenTrade consignment lookup
      add :lookup_status, :string, null: false, default: "pending"
      add :lookup_message, :string
      add :lookup_at, :utc_datetime
      add :consignment, :map, null: false, default: %{}
      add :importer_name, :string
      add :goods_description, :text
      add :hs_code, :string
      add :ucr_number, :string

      # Clearance
      add :certificate_number, :string
      add :cleared_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:applications, [:reference])
    create unique_index(:applications, [:occupancy_ref])
    create unique_index(:applications, [:certificate_number])
    create index(:applications, [:stage])
    create index(:applications, [:container_number])

    # ---- M3 CAS adjudication
    create table(:adjudications) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :decision, :string, null: false
      add :classification, :string, null: false
      add :reason, :text, null: false
      add :user_id, references(:users, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:adjudications, [:application_id])

    # ---- M4 field inspection
    create table(:inspections) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :isotope, :string, null: false
      add :dose_rate_usv_h, :decimal, precision: 10, scale: 3, null: false
      add :findings, :text, null: false
      add :outcome, :string, null: false
      add :photos, {:array, :string}, null: false, default: []
      add :user_id, references(:users, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:inspections, [:application_id])

    # ---- M5 screening report (maker-checker)
    create table(:reports) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "submitted"
      add :result, :string, null: false
      add :narrative, :text, null: false
      add :maker_id, references(:users, on_delete: :restrict), null: false
      add :submitted_at, :utc_datetime, null: false
      add :checker_id, references(:users, on_delete: :restrict)
      add :decided_at, :utc_datetime
      add :rejection_reason, :text

      timestamps(type: :utc_datetime)
    end

    create index(:reports, [:application_id])

    # ---- M6 invoices & payments
    create table(:invoices) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :number, :string, null: false
      add :fee_schedule_id, references(:fee_schedules, on_delete: :restrict), null: false
      add :description, :string, null: false
      add :amount_usd, :decimal, precision: 12, scale: 2, null: false
      add :amount_kes, :decimal, precision: 12, scale: 2, null: false
      add :status, :string, null: false, default: "pending"
      add :paid_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invoices, [:number])
    create unique_index(:invoices, [:application_id])

    create table(:payments) do
      add :invoice_id, references(:invoices, on_delete: :restrict)
      add :method, :string, null: false
      add :reference, :string, null: false
      add :account_reference, :string
      add :amount_kes, :decimal, precision: 12, scale: 2, null: false
      add :payer, :string
      add :received_at, :utc_datetime, null: false
      add :status, :string, null: false
      add :recorded_by_id, references(:users, on_delete: :nilify_all)
      add :raw, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:payments, [:method, :reference])
    create index(:payments, [:invoice_id])
    create index(:payments, [:status])

    # ---- M2 integration message log
    create table(:integration_logs) do
      add :system, :string, null: false
      add :operation, :string, null: false
      add :object_ref, :string
      add :request, :map, null: false, default: %{}
      add :response, :map, null: false, default: %{}
      add :http_status, :integer
      add :outcome, :string, null: false
      add :duration_ms, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:integration_logs, [:system, :inserted_at])
    create index(:integration_logs, [:object_ref])
  end
end
