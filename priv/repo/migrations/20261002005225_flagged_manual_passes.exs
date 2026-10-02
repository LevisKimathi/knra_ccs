defmodule Knra.Repo.Migrations.FlaggedManualPasses do
  use Ecto.Migration

  # An RPM operator may record a pass that KenTrade could not confirm (not
  # found, transit, or KenTrade unavailable) by giving a reason. Such passes are
  # flagged for supervisor review.
  def change do
    alter table(:applications) do
      add :override_reason, :text
      # nil (not flagged) | "pending" | "reviewed"
      add :review_status, :string
      add :reviewed_by_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
      add :review_note, :text
    end

    create index(:applications, [:review_status])
  end
end
