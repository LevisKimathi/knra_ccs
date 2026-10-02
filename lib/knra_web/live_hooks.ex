defmodule KnraWeb.LiveHooks do
  @moduledoc """
  `on_mount` hooks for authenticated LiveViews.

    * `:default` — subscribes to application, device and role notification
      broadcasts, keeps the nav counters live and shows notifications as toasts.
      `{:application, ...}` and `{:lane_updated, ...}` messages are passed on to
      the LiveView when it implements `handle_info/2`.
    * `{:authorize, permission}` — redirects users whose role lacks the permission.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Knra.Accounts.Policy
  alias Knra.{Accounts, Billing, Devices, Notifications, Screening}

  def on_mount(:default, _params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Screening.subscribe()
      Devices.subscribe()
      Notifications.subscribe(scope)
      Knra.Accounts.Roles.subscribe()
      Accounts.touch_last_active(scope.user)
    end

    socket =
      socket
      |> assign(:nav_counts, nav_counts(scope))
      |> assign(:seen_notifications, [])
      |> attach_hook(:knra_broadcasts, :handle_info, &handle_broadcast/2)

    {:cont, socket}
  end

  def on_mount({:authorize, permission}, _params, _session, socket) do
    if Policy.can?(socket.assigns.current_scope, permission) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "Your role does not have access to that screen.")
       |> redirect(to: KnraWeb.Endpoint.path("/"))}
    end
  end

  def on_mount(:simulator, _params, _session, socket) do
    if Knra.Simulator.enabled?() do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "Simulators are disabled in this environment.")
       |> redirect(to: KnraWeb.Endpoint.path("/"))}
    end
  end

  # A notice can arrive on several of the user's permission topics; show it once
  defp handle_broadcast({:notification, n}, socket) do
    if n.id in socket.assigns.seen_notifications do
      {:halt, socket}
    else
      {:halt,
       socket
       |> assign(:seen_notifications, Enum.take([n.id | socket.assigns.seen_notifications], 20))
       |> put_flash(if(n.level == :error, do: :error, else: :info), n.message)}
    end
  end

  # A role was edited: rebuild the menu and counts with the new permissions
  defp handle_broadcast(:roles_changed, socket) do
    {:halt, assign(socket, :nav_counts, nav_counts(socket.assigns.current_scope))}
  end

  defp handle_broadcast({:application, _, _, _} = msg, socket) do
    socket = assign(socket, :nav_counts, nav_counts(socket.assigns.current_scope))
    forward(msg, socket)
  end

  defp handle_broadcast({:lane_updated, _} = msg, socket), do: forward(msg, socket)
  defp handle_broadcast(_msg, socket), do: {:cont, socket}

  defp forward(_msg, socket) do
    if function_exported?(socket.view, :handle_info, 2),
      do: {:cont, socket},
      else: {:halt, socket}
  end

  @doc false
  def nav_counts(scope) do
    stages = Screening.stage_counts()

    drafts? = Policy.can?(scope, :draft_report)
    verifies? = Policy.can?(scope, :verify_report)

    reports =
      cond do
        drafts? and not verifies? -> Map.get(stages, "report_draft", 0)
        verifies? and not drafts? -> Map.get(stages, "report_check", 0)
        true -> Map.get(stages, "report_draft", 0) + Map.get(stages, "report_check", 0)
      end

    %{
      "alarms" => Map.get(stages, "alarm", 0),
      "inspections" => Map.get(stages, "secondary", 0),
      "reports" => reports,
      "payments" =>
        if(Policy.can?(scope, :reconcile_payments),
          do: Billing.count_unmatched_payments(),
          else: 0
        ),
      "flagged" => if(Policy.can?(scope, :review_flagged), do: Screening.count_flagged(), else: 0)
    }
  end
end
