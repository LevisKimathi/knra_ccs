defmodule Knra.Notifications do
  @moduledoc """
  Notifications & alerts (M11).

  In-app notices are broadcast per role on `"notifications:<role>"`; every
  authenticated LiveView subscribes through `KnraWeb.Notify` and shows them as
  toasts. Detentions and device faults are also emailed to supervisors.
  """

  require Logger

  alias Knra.Accounts
  alias Knra.Accounts.UserNotifier
  alias Knra.Screening.Application

  def subscribe(role), do: Phoenix.PubSub.subscribe(Knra.PubSub, topic(role))

  # Super admins see every notification.
  def notify(roles, level, message, path \\ nil) do
    for role <- Enum.uniq(List.wrap(roles) ++ ["super_admin"]) do
      Phoenix.PubSub.broadcast(
        Knra.PubSub,
        topic(role),
        {:notification, %{level: level, message: message, path: path}}
      )
    end

    :ok
  end

  def alarm_raised(%Application{} = app) do
    notify(
      ["cas_operator", "supervisor"],
      :error,
      "Radiation alarm on #{lane(app)} — #{c(app)} awaiting adjudication.",
      "/applications/#{app.reference}"
    )
  end

  def secondary_assigned(%Application{} = app) do
    notify(
      "field_officer",
      :info,
      "#{c(app)} diverted to secondary inspection.",
      "/applications/#{app.reference}"
    )
  end

  def detention(%Application{} = app, scope) do
    msg = "#{c(app)} (#{app.reference}) detained by #{scope.user.name}."
    notify(["supervisor", "cas_operator"], :error, msg, "/applications/#{app.reference}")

    email_supervisors("DETENTION: #{c(app)} — #{app.reference}", """
    #{msg}

    Review the application and its audit trail:
    #{url("/applications/#{app.reference}")}
    """)
  end

  def cleared(%Application{} = app) do
    notify(
      ["cas_operator", "checking_officer", "verification_officer", "supervisor"],
      :info,
      "#{c(app)} cleared — certificate #{app.certificate_number} issued.",
      "/applications/#{app.reference}"
    )
  end

  def device_fault(lane, scope, reason) do
    msg =
      "#{lane.name} (#{lane.device_code}) marked out of service by #{scope.user.name}: #{reason}"

    notify(["supervisor", "cas_operator"], :error, msg, "/admin/devices")
    email_supervisors("RPM out of service: #{lane.name}", msg)
  end

  # Alert emails are best effort: a mail outage must never undo or break the
  # detention / device-fault action that triggered them.
  defp email_supervisors(subject, body) do
    for u <-
          Accounts.list_active_users_by_role("supervisor") ++
            Accounts.list_active_users_by_role("super_admin") do
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

  defp topic(role), do: "notifications:#{role}"
  defp c(app), do: Application.display_container(app.container_number)
  defp lane(%{lane: %{name: n}}), do: n
  defp lane(_), do: "RPM"
  # Endpoint.path/1 adds the PHX_PATH prefix (e.g. /knra) when served under a sub-path
  defp url(path), do: KnraWeb.Endpoint.url() <> KnraWeb.Endpoint.path(path)
end
