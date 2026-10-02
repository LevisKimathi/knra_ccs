defmodule Knra.Repo.Migrations.ManualRpmPasses do
  use Ecto.Migration

  # The CAS system does not capture container numbers, so RPM operators record
  # passes by hand. Detector counts are then optional (only with a RIID reading),
  # and each application records how it was captured, by whom, and evidence photos.
  def change do
    alter table(:applications) do
      modify :gamma_cps, :integer, null: true, from: {:integer, null: false}
      modify :neutron_cps, :integer, null: true, from: {:integer, null: false}
      add :source, :string, null: false, default: "rpm_feed"
      add :recorded_by_id, references(:users, on_delete: :nilify_all)
      add :evidence_photos, {:array, :string}, null: false, default: []
    end

    create index(:applications, [:recorded_by_id, :scanned_at])
  end
end
