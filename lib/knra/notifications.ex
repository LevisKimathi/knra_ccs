defmodule Knra.Notifications do
  @moduledoc """
  Notifications & alerts (M11).

  In-app notices go to everyone whose role holds a given permission (e.g. alarms
  to those who can see the alarm queue), on `"notifications:<permission>"`.
  Every authenticated LiveView subscribes, through `KnraWeb.LiveHooks`, to the
  topics of its user's permissions and shows notices as toasts (once, even when
  several of the user's permissions match). Detentions and device faults are also
  emailed to users whose role has "Receive alert emails".
  """

  require Logger

  alias Knra.Accounts
  alias Knra.Accounts.UserNotifier
  alias Knra.Screening.Application

  @doc "Subscribes the calling process to notices for every permission the user holds."
  def subscribe(scope) do
    for p <- Knra.Accounts.Policy.permissions(), Knra.Accounts.Policy.can?(scope, p) do
      Phoenix.PubSub.subscribe(Knra.PubSub, topic(p))
    end

    :ok
  end

  @doc "Sends a notice to users holding any of `permissions`; `id` lets a user see it once."
  def notify(permissions, level, message, path \\ nil) do
    notice = %{id: System.unique_integer([:positive]), level: level, message: message, path: path}

    for p <- List.wrap(permissions) do
      Phoenix.PubSub.broadcast(Knra.PubSub, topic(p), {:notification, notice})
    end

    :ok
  end

  def alarm_raised(%Application{} = app) do
    notify(
      [:adjudicate, :view_lanes],
      :error,
      "Radiation alarm on #{lane(app)} — #{c(app)} awaiting adjudication.",
      "/applications/#{app.reference}"
    )
  end

  def secondary_assigned(%Application{} = app) do
    notify(
      :inspect,
      :info,
      "#{c(app)} diverted to secondary inspection.",
      "/applications/#{app.reference}"
    )
  end

  def detention(%Application{} = app, scope) do
    msg = "#{c(app)} (#{app.reference}) detained by #{scope.user.name}."
    notify([:adjudicate, :view_lanes], :error, msg, "/applications/#{app.reference}")

    email_supervisors("DETENTION: #{c(app)} — #{app.reference}", """
    #{msg}

    Review the application and its audit trail:
    #{url("/applications/#{app.reference}")}
    """)
  end

  def flagged_for_review(%Application{} = app) do
    notify(
      :review_flagged,
      :error,
      "#{c(app)} (#{app.reference}) recorded without KenTrade confirmation — review needed.",
      "/reviews"
    )
  end

  def cleared(%Application{} = app) do
    notify(
      [:view_lanes, :draft_report, :verify_report],
      :info,
      "#{c(app)} cleared — certificate #{app.certificate_number} issued.",
      "/applications/#{app.reference}"
    )
  end

  def device_fault(lane, scope, reason) do
    msg =
      "#{lane.name} (#{lane.device_code}) marked out of service by #{scope.user.name}: #{reason}"

    notify([:view_lanes, :manage_devices], :error, msg, "/admin/devices")
    email_supervisors("RPM out of service: #{lane.name}", msg)
  end

  # Alert emails go to roles with "Receive alert emails" (and super admins). Best effort: a mail outage must never undo or break the
  # detention / device-fault action that triggered them.
  defp email_supervisors(subject, body) do
    for u <- Accounts.list_active_users_with_permission(:receive_alert_emails) do
      try do
        UserNotifier.deliver(u.email, subject, body)
      rescue
        e -> Logger.error("Alert email to #{u.email} failed: #{Exception.message(e)}")
      catch
        :exit, reason -> Logger.error("Alert email to #{u.email} failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp topic(permission), do: "notifications:#{permission}"
  defp c(app), do: Application.display_container(app.container_number)
  defp lane(%{lane: %{name: n}}), do: n
  defp lane(_), do: "RPM"
  # Endpoint.path/1 adds the PHX_PATH prefix (e.g. /knra) when served under a sub-path
  defp url(path), do: KnraWeb.Endpoint.url() <> KnraWeb.Endpoint.path(path)
end
