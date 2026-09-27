defmodule Knra.Audit do
  @moduledoc """
  Append-only, hash-chained audit trail (M10).

  Every entry stores the SHA-256 of the previous entry's hash plus its own content,
  so any edit or deletion made outside the application breaks the chain and is
  reported by `verify_chain/0`. The database also rejects UPDATE and DELETE.

  Entries about a screening application double as that application's timeline.
  """

  import Ecto.Query

  alias Knra.Repo
  alias Knra.Accounts.{Scope, User}
  alias Knra.Audit.Entry

  @genesis String.duplicate("0", 64)
  @lock_key 7_310_001

  @doc """
  Appends an entry. `actor` is a `%Scope{}`, a `%User{}`, or a string naming a
  system actor such as `"KenTrade TradeNet"` or `"RPM Lane 2"`.

  Must be called inside a transaction when used together with other writes;
  it takes a transaction-scoped advisory lock to serialise the chain.
  """
  def log(actor, object_type, object_ref, action, note \\ nil) do
    {actor_id, actor_name} = actor_fields(actor)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])

      prev =
        Repo.one(from e in Entry, order_by: [desc: e.id], limit: 1, select: e.hash) ||
          @genesis

      now = DateTime.utc_now()

      attrs = %{
        object_type: to_string(object_type),
        object_ref: to_string(object_ref),
        actor_id: actor_id,
        actor_name: actor_name,
        action: action,
        note: blank_to_nil(note),
        prev_hash: prev,
        inserted_at: now
      }

      entry = struct(Entry, Map.put(attrs, :hash, compute_hash(attrs)))
      Repo.insert!(entry)
    end)
    |> case do
      {:ok, entry} -> entry
      {:error, reason} -> raise "audit log failed: #{inspect(reason)}"
    end
  end

  @doc "Timeline for one object, oldest first."
  def timeline(object_type, object_ref) do
    Repo.all(
      from e in Entry,
        where: e.object_type == ^to_string(object_type) and e.object_ref == ^object_ref,
        order_by: [asc: e.id]
    )
  end

  @doc """
  Searches the audit trail. Supported filters: `"q"` (object ref / action / note),
  `"actor"`, `"object_type"`, `"from"` and `"to"` (ISO dates, Nairobi time).
  """
  def search(filters \\ %{}, limit \\ 200) do
    Entry
    |> filter(filters)
    |> order_by([e], desc: e.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter(query, filters) do
    Enum.reduce(filters, query, fn
      {"q", q}, query when q not in [nil, ""] ->
        like = "%" <> q <> "%"

        where(
          query,
          [e],
          ilike(e.object_ref, ^like) or ilike(e.action, ^like) or ilike(e.note, ^like)
        )

      {"actor", a}, query when a not in [nil, ""] ->
        where(query, [e], ilike(e.actor_name, ^("%" <> a <> "%")))

      {"object_type", t}, query when t not in [nil, ""] ->
        where(query, [e], e.object_type == ^t)

      {"from", d}, query when d not in [nil, ""] ->
        case Date.from_iso8601(d) do
          {:ok, date} -> where(query, [e], e.inserted_at >= ^Knra.Time.start_of_day_utc(date))
          _ -> query
        end

      {"to", d}, query when d not in [nil, ""] ->
        case Date.from_iso8601(d) do
          {:ok, date} ->
            where(query, [e], e.inserted_at < ^Knra.Time.start_of_day_utc(Date.add(date, 1)))

          _ ->
            query
        end

      _, query ->
        query
    end)
  end

  @doc """
  Recomputes the whole chain. Returns `:ok` or `{:error, entry_id}` for the first
  entry whose hash or back-link does not match.
  """
  def verify_chain do
    Repo.transaction(fn ->
      Entry
      |> order_by(asc: :id)
      |> Repo.stream(max_rows: 1000)
      |> Enum.reduce_while(@genesis, fn e, prev ->
        attrs = Map.take(e, [:object_type, :object_ref, :actor_id, :actor_name, :action, :note, :prev_hash, :inserted_at])

        if e.prev_hash == prev and compute_hash(attrs) == e.hash,
          do: {:cont, e.hash},
          else: {:halt, {:broken, e.id}}
      end)
    end)
    |> case do
      {:ok, {:broken, id}} -> {:error, id}
      {:ok, _} -> :ok
    end
  end

  def entry_count, do: Repo.aggregate(Entry, :count)

  @doc "CSV export of a search result."
  def to_csv(entries) do
    header = "time_utc,object_type,object,actor,action,note,hash\n"

    rows =
      Enum.map(entries, fn e ->
        [DateTime.to_iso8601(e.inserted_at), e.object_type, e.object_ref, e.actor_name, e.action, e.note || "", e.hash]
        |> Enum.map_join(",", &csv_cell/1)
        |> Kernel.<>("\n")
      end)

    IO.iodata_to_binary([header | rows])
  end

  defp csv_cell(v) do
    v = to_string(v)
    if String.contains?(v, [",", "\"", "\n"]), do: ~s("#{String.replace(v, "\"", "\"\"")}"), else: v
  end

  defp compute_hash(attrs) do
    payload =
      Enum.join(
        [
          attrs.prev_hash,
          attrs.object_type,
          attrs.object_ref,
          attrs.actor_id || "",
          attrs.actor_name,
          attrs.action,
          attrs.note || "",
          DateTime.to_iso8601(attrs.inserted_at)
        ],
        "|"
      )

    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp actor_fields(%Scope{user: user}), do: actor_fields(user)
  defp actor_fields(%User{id: id, name: name, email: email}), do: {id, if(name in [nil, ""], do: email, else: name)}
  defp actor_fields(name) when is_binary(name), do: {nil, name}

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v
end
