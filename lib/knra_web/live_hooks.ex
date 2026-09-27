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
      Notifications.subscribe(scope.user.role)
      Accounts.touch_last_active(scope.user)
    end

    socket =
      socket
      |> assign(:nav_counts, nav_counts(scope))
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
       |> redirect(to: "/")}
    end
  end

  def on_mount(:simulator, _params, _session, socket) do
    if Knra.Simulator.enabled?() do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "Simulators are disabled in this environment.")
       |> redirect(to: "/")}
    end
  end

  defp handle_broadcast({:notification, n}, socket) do
    {:halt, put_flash(socket, if(n.level == :error, do: :error, else: :info), n.message)}
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

    reports =
      case scope.user.role do
        "checking_officer" -> Map.get(stages, "report_draft", 0)
        "verification_officer" -> Map.get(stages, "report_check", 0)
        _ -> Map.get(stages, "report_draft", 0) + Map.get(stages, "report_check", 0)
      end

    %{
      "alarms" => Map.get(stages, "alarm", 0),
      "inspections" => Map.get(stages, "secondary", 0),
      "reports" => reports,
      "payments" =>
        if(Policy.can?(scope, :reconcile_payments),
          do: Billing.count_unmatched_payments(),
          else: 0
        )
    }
  end
end
