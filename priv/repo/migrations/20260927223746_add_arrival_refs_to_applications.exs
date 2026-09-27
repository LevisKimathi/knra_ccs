defmodule Knra.Repo.Migrations.AddArrivalRefsToApplications do
  use Ecto.Migration

  # Containers are reused across voyages, so each screening records which arrival
  # it belongs to: the manifest, bills of lading and UCRs KenTrade returned at scan
  # time. `consignment_refs` holds them normalised (upper case, no spaces/hyphens)
  # for matching status queries.
  def change do
    alter table(:applications) do
      add :manifest_number, :string
      add :arrived_at, :utc_datetime
      add :consignment_refs, {:array, :string}, null: false, default: []
    end

    create index(:applications, [:container_number, :scanned_at])
    create index(:applications, [:consignment_refs], using: :gin)

    execute(
      """
      UPDATE applications SET
        manifest_number = consignment #>> '{movement,vesselCall,manifestNumber}',
        arrived_at = (consignment #>> '{movement,vesselCall,estimatedArrival}')::timestamptz,
        consignment_refs = ARRAY(
          SELECT DISTINCT regexp_replace(upper(x), '[\\s-]', '', 'g')
          FROM (
            SELECT consignment #>> '{movement,vesselCall,manifestNumber}' AS x
            UNION ALL
            SELECT c ->> 'billOfLadingNumber'
              FROM jsonb_array_elements(COALESCE(consignment #> '{movement,consignments}', '[]'::jsonb)) c
            UNION ALL
            SELECT c ->> 'ucrNumber'
              FROM jsonb_array_elements(COALESCE(consignment #> '{movement,consignments}', '[]'::jsonb)) c
          ) refs
          WHERE x IS NOT NULL AND x <> ''
        )
      """,
      ""
    )
  end
end
