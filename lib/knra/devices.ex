defmodule Knra.Devices do
  @moduledoc """
  RPM device & lane management (M8). Lanes marked out of service are skipped when
  the RPM simulator routes traffic, and RPM events on them are rejected.
  """

  import Ecto.Query

  alias Knra.{Audit, Repo}
  alias Knra.Accounts.Policy
  alias Knra.Devices.Lane

  @topic "devices"

  def subscribe, do: Phoenix.PubSub.subscribe(Knra.PubSub, @topic)

  def list_lanes, do: Repo.all(from l in Lane, order_by: l.name)
  def list_in_service_lanes, do: Repo.all(from l in Lane, where: l.in_service, order_by: l.name)
  def get_lane!(id), do: Repo.get!(Lane, id)
  def get_lane_by_code(code), do: Repo.get_by(Lane, device_code: code)

  def change_lane(lane, attrs \\ %{}), do: Lane.changeset(lane, attrs)

  def create_lane(scope, attrs) do
    with :ok <- Policy.authorize(scope, :manage_devices) do
      Repo.transaction(fn ->
        case Repo.insert(Lane.changeset(%Lane{}, attrs)) do
          {:ok, lane} ->
            Audit.log(
              scope,
              :device,
              lane.device_code,
              "Device registered on #{lane.name}",
              lane.serial_number
            )

            lane

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
      |> broadcast()
    end
  end

  def update_lane(scope, %Lane{} = lane, attrs) do
    with :ok <- Policy.authorize(scope, :manage_devices) do
      Repo.transaction(fn ->
        case Repo.update(Lane.changeset(lane, attrs)) do
          {:ok, updated} ->
            Audit.log(
              scope,
              :device,
              updated.device_code,
              "Device details updated",
              changes_note(lane, updated)
            )

            updated

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
      |> broadcast()
    end
  end

  @doc "Takes a lane out of service. A reason is mandatory."
  def mark_out_of_service(scope, %Lane{} = lane, reason) do
    reason = String.trim(reason || "")

    with :ok <- Policy.authorize(scope, :manage_devices),
         :ok <- require_reason(reason) do
      Repo.transaction(fn ->
        updated =
          lane
          |> Ecto.Changeset.change(in_service: false, status_reason: reason)
          |> Repo.update!()

        Audit.log(scope, :device, lane.device_code, "Device marked out of service", reason)
        updated
      end)
      |> broadcast()
      |> tap(fn
        {:ok, l} -> Knra.Notifications.device_fault(l, scope, reason)
        _ -> :ok
      end)
    end
  end

  def return_to_service(scope, %Lane{} = lane, note \\ nil) do
    with :ok <- Policy.authorize(scope, :manage_devices) do
      Repo.transaction(fn ->
        updated =
          lane |> Ecto.Changeset.change(in_service: true, status_reason: nil) |> Repo.update!()

        Audit.log(scope, :device, lane.device_code, "Device returned to service", note)
        updated
      end)
      |> broadcast()
    end
  end

  defp require_reason(""), do: {:error, :reason_required}
  defp require_reason(_), do: :ok

  defp changes_note(old, new) do
    [:name, :serial_number, :detector_type, :terminal, :calibration_due_on]
    |> Enum.filter(&(Map.get(old, &1) != Map.get(new, &1)))
    |> Enum.map_join("; ", &"#{&1}: #{Map.get(old, &1)} → #{Map.get(new, &1)}")
  end

  defp broadcast({:ok, lane} = result) do
    Phoenix.PubSub.broadcast(Knra.PubSub, @topic, {:lane_updated, lane})
    result
  end

  defp broadcast(other), do: other
end
