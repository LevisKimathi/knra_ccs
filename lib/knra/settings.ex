defmodule Knra.Settings do
  @moduledoc """
  System settings (Administration → System Settings), changed by users whose role
  has "Manage system settings" (super admins by default). Each change is audited.

  The catalogue below defines every setting and its default; only changed values
  are stored. Reads use an in-memory copy reloaded on change (and on other nodes
  via PubSub); with `config :knra, :settings_cache, false` (tests) every read hits
  the database.
  """

  import Ecto.Query

  alias Knra.{Audit, Repo}
  alias Knra.Accounts.Policy
  alias Knra.Settings.Setting

  @cache_key {__MODULE__, :values}
  @topic "settings"

  @definitions [
    %{
      key: "rpm_override_enabled",
      group: "RPM operators",
      label: "Allow Record Anyway",
      description:
        "RPM operators may record a pass KenTrade cannot confirm (not found, transit, or KenTrade unavailable) by giving a reason. Such passes are flagged for supervisor review.",
      default: true
    },
    %{
      key: "auto_clear_no_alarm",
      group: "Clearance",
      label: "Auto-clear passes with no alarm",
      description:
        "When the RPM shows no alarm, approve the container automatically: no screening report and no verification. Flagged passes (recorded without KenTrade confirmation) are never auto-cleared.",
      default: false,
      risky: true
    },
    %{
      key: "auto_clear_wait_for_payment",
      group: "Clearance",
      label: "Wait for the screening fee before auto-clearing",
      description:
        "On: an auto-approved container is cleared and its certificate issued once the fee is paid. Off: it is cleared immediately and the fee stays owed.",
      default: true,
      depends_on: "auto_clear_no_alarm"
    }
  ]

  def definitions, do: @definitions

  defp definition(key),
    do: Enum.find(@definitions, &(&1.key == key)) || raise("unknown setting #{key}")

  @doc "Current value of a boolean setting."
  def enabled?(key) do
    definition = definition(key)

    case Map.get(stored(), key) do
      nil -> definition.default
      %Setting{value: v} -> v == "true"
    end
  end

  @doc "Every setting with its current value and who last changed it."
  def list do
    stored = Repo.all(from s in Setting, preload: :updated_by) |> Map.new(&{&1.key, &1})

    Enum.map(@definitions, fn d ->
      s = stored[d.key]
      Map.merge(d, %{value: if(s, do: s.value == "true", else: d.default), changed: s})
    end)
  end

  @doc "Sets a boolean setting."
  def put(scope, key, value) when is_boolean(value) do
    d = definition(key)

    with :ok <- Policy.authorize(scope, :manage_settings) do
      Repo.transaction(fn ->
        now = DateTime.utc_now(:second)

        Repo.insert!(
          %Setting{key: key, value: to_string(value), updated_by_id: scope.user.id},
          on_conflict: [
            set: [value: to_string(value), updated_by_id: scope.user.id, updated_at: now]
          ],
          conflict_target: :key
        )

        Audit.log(scope, :setting, key, "#{d.label}: #{if value, do: "on", else: "off"}")
        value
      end)
      |> tap(fn
        {:ok, _} -> changed()
        _ -> :ok
      end)
    end
  end

  defp stored do
    if Application.get_env(:knra, :settings_cache, true) do
      case :persistent_term.get(@cache_key, nil) do
        nil -> reload()
        values -> values
      end
    else
      load()
    end
  end

  defp load, do: Repo.all(Setting) |> Map.new(&{&1.key, &1})

  def reload do
    values = load()

    if Application.get_env(:knra, :settings_cache, true),
      do: :persistent_term.put(@cache_key, values)

    values
  end

  def subscribe, do: Phoenix.PubSub.subscribe(Knra.PubSub, @topic)

  defp changed do
    reload()
    Phoenix.PubSub.broadcast(Knra.PubSub, @topic, :settings_changed)
  end
end
