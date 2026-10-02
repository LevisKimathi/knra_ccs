defmodule Knra.ConfigCache do
  @moduledoc """
  Keeps the in-memory copies of roles and system settings current: reloads them
  when any node changes a role or setting.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Knra.Accounts.Roles.subscribe()
    Knra.Settings.subscribe()
    {:ok, nil}
  end

  @impl true
  def handle_info(:roles_changed, state) do
    Knra.Accounts.Roles.reload()
    {:noreply, state}
  end

  def handle_info(:settings_changed, state) do
    Knra.Settings.reload()
    {:noreply, state}
  end
end
