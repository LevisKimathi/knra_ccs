defmodule Knra.Accounts.RoleCache do
  @moduledoc "Reloads the in-memory roles when any node changes a role."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    Knra.Accounts.Roles.subscribe()
    {:ok, nil}
  end

  @impl true
  def handle_info(:roles_changed, state) do
    Knra.Accounts.Roles.reload()
    {:noreply, state}
  end
end
