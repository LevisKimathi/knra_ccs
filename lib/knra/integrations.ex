defmodule Knra.Integrations do
  @moduledoc """
  Integration layer (M2): message log of every outbound call and a health view
  for the supervisor.
  """

  import Ecto.Query
  alias Knra.Repo
  alias Knra.Integrations.Log

  def record(attrs) do
    %Log{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  def list_logs(filters \\ %{}, limit \\ 100) do
    Log
    |> then(fn q ->
      case filters["q"] do
        q_str when q_str not in [nil, ""] -> where(q, [l], ilike(l.object_ref, ^"%#{q_str}%"))
        _ -> q
      end
    end)
    |> then(fn q ->
      case filters["system"] do
        sys when sys not in [nil, ""] -> where(q, [l], l.system == ^sys)
        _ -> q
      end
    end)
    |> then(fn q ->
      case filters["outcome"] do
        o when o not in [nil, ""] -> where(q, [l], l.outcome == ^o)
        _ -> q
      end
    end)
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Health summary per system over the last 24 hours."
  def health(system) do
    since = DateTime.add(Knra.Time.now(), -24 * 3600, :second)

    stats =
      Repo.all(
        from l in Log,
          where: l.system == ^system and l.inserted_at >= ^since,
          group_by: l.outcome,
          select: {l.outcome, count(l.id)}
      )
      |> Map.new()

    last = Repo.one(from l in Log, where: l.system == ^system, order_by: [desc: l.id], limit: 1)

    last_ok =
      Repo.one(
        from l in Log,
          where: l.system == ^system and l.outcome in ["found", "transit", "not_found"],
          order_by: [desc: l.id],
          limit: 1
      )

    %{
      stats: stats,
      total: stats |> Map.values() |> Enum.sum(),
      failures:
        Map.get(stats, "error", 0) + Map.get(stats, "unauthorized", 0) +
          Map.get(stats, "invalid_request", 0) + Map.get(stats, "forbidden", 0),
      last: last,
      last_ok: last_ok,
      healthy?: is_nil(last) or last.outcome in ["found", "transit", "not_found"]
    }
  end
end
