defmodule Knra.Screening.StatusQuery do
  @moduledoc """
  Answers KenTrade's container status query.

  Containers are reused, so one container number can have many screenings over
  time, each for a different arrival (manifest / bill of lading / UCR). To give
  KenTrade the status for the *right* arrival:

    * When the request item names the arrival (`manifestNumber`,
      `billOfLadingNumber` or `ucrNumber`), only a screening recorded against that
      arrival is returned. If there is none, the answer is `NOT_FOUND` — even if the
      same container was screened on an earlier voyage.
    * When only `containerNumber` is sent, the latest screening is returned, but
      only if it happened within `:status_window_days` (default 60, KenTrade's own
      default search window). Older screenings belong to a previous arrival.

  Every answer carries the manifest, B/L, UCR and scan time of the screening it
  is based on, so KenTrade can confirm it matches its record.

  Status values: `CLEARED`, `DETAINED`, `IN_PROGRESS` (screening not finished;
  `stage` gives the detail) and `NOT_FOUND`.
  """

  import Ecto.Query

  alias Knra.Repo
  alias Knra.Integrations.KenTrade
  alias Knra.Screening.Application

  @max_items 100
  @ref_fields ~w(manifestNumber billOfLadingNumber ucrNumber)

  def max_items, do: @max_items

  def window_days, do: Elixir.Application.get_env(:knra, :status_window_days, 60)

  @doc "Resolves a list of request items (maps with `\"containerNumber\"`) to status maps, in order."
  def lookup(items) when is_list(items) do
    containers =
      items
      |> Enum.flat_map(fn
        %{"containerNumber" => c} when is_binary(c) and c != "" -> [KenTrade.normalise(c)]
        _ -> []
      end)
      |> Enum.uniq()

    history =
      Repo.all(
        from a in Application,
          where: a.container_number in ^containers,
          order_by: [desc: a.scanned_at, desc: a.id]
      )
      |> Enum.group_by(& &1.container_number)

    since = DateTime.add(Knra.Time.now(), -window_days() * 86_400, :second)

    Enum.map(items, &resolve(&1, history, since))
  end

  defp resolve(%{"containerNumber" => sent} = item, history, since)
       when is_binary(sent) and sent != "" do
    apps = Map.get(history, KenTrade.normalise(sent), [])

    refs =
      @ref_fields
      |> Enum.map(&Application.normalise_ref(item[&1]))
      |> Enum.reject(&(&1 in [nil, ""]))

    case match(apps, refs, since) do
      {app, matched_by} -> found(sent, app, matched_by)
      nil -> %{"containerNumber" => sent, "status" => "NOT_FOUND"}
    end
  end

  defp resolve(item, _history, _since) do
    %{
      "containerNumber" => if(is_map(item), do: item["containerNumber"]),
      "status" => "INVALID_REQUEST",
      "message" => "containerNumber is required."
    }
  end

  # Identifiers given: match the arrival. If the only recent screening has no
  # KenTrade identifiers (the lookup failed at scan time) it cannot be checked
  # against the arrival, so it is returned flagged as CONTAINER_ONLY.
  defp match(apps, [_ | _] = refs, since) do
    case Enum.find(apps, fn a -> Enum.any?(refs, &(&1 in a.consignment_refs)) end) do
      %Application{} = app ->
        {app, "ARRIVAL"}

      nil ->
        case recent(apps, since) do
          %Application{consignment_refs: []} = app -> {app, "CONTAINER_ONLY"}
          _ -> nil
        end
    end
  end

  defp match(apps, [], since) do
    case recent(apps, since) do
      nil -> nil
      app -> {app, "CONTAINER"}
    end
  end

  defp recent([%Application{scanned_at: at} = latest | _], since) do
    if DateTime.compare(at, since) != :lt, do: latest
  end

  defp recent([], _since), do: nil

  defp found(sent, %Application{} = a, matched_by) do
    consignments = get_in(a.consignment, ["movement", "consignments"]) |> List.wrap()

    %{
      "containerNumber" => sent,
      "status" => status(a.stage),
      "stage" => stage(a.stage),
      "applicationReference" => a.reference,
      "screenedAt" => Knra.Time.iso_local(a.scanned_at),
      "clearedAt" => a.cleared_at && Knra.Time.iso_local(a.cleared_at),
      "certificateNumber" => a.certificate_number,
      "manifestNumber" => a.manifest_number,
      "billOfLadingNumbers" =>
        consignments |> Enum.map(& &1["billOfLadingNumber"]) |> Enum.reject(&is_nil/1),
      "ucrNumbers" => consignments |> Enum.map(& &1["ucrNumber"]) |> Enum.reject(&is_nil/1),
      "matchedBy" => matched_by
    }
  end

  defp status("cleared"), do: "CLEARED"
  defp status("detained"), do: "DETAINED"
  defp status(_), do: "IN_PROGRESS"

  defp stage("alarm"), do: "ALARM_ADJUDICATION"
  defp stage("secondary"), do: "SECONDARY_INSPECTION"
  defp stage("report_draft"), do: "REPORT_PENDING"
  defp stage("report_check"), do: "VERIFICATION_PENDING"
  defp stage("approved"), do: "AWAITING_PAYMENT"
  defp stage("cleared"), do: "CLEARED"
  defp stage("detained"), do: "DETAINED"
end
