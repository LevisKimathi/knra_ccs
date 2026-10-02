defmodule KnraWeb.Admin.SettingsLive do
  @moduledoc """
  System settings: rules that change how the screening workflow behaves.
  Requires "Manage system settings" (super admins by default). Every change is
  audited and takes effect immediately.
  """
  use KnraWeb, :live_view

  on_mount {KnraWeb.LiveHooks, {:authorize, :manage_settings}}

  alias Knra.Settings

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      nav_counts={@nav_counts}
      active="settings"
    >
      <.page_header title="System Settings">
        <:subtitle>
          Rules for how the screening workflow behaves. Changes take effect immediately for new RPM
          passes and are recorded in the audit trail.
        </:subtitle>
      </.page_header>

      <div class="max-w-3xl space-y-6">
        <section :for={{group, settings} <- @groups}>
          <h2 class="mb-2 text-[11px] font-bold uppercase tracking-[0.08em] text-subtle">{group}</h2>
          <div class="rounded-md border border-line bg-white">
            <div
              :for={s <- settings}
              id={"setting-#{s.key}"}
              class={[
                "flex gap-4 border-b border-line-soft px-5 py-4 last:border-0",
                inactive?(s, @values) && "opacity-55"
              ]}
            >
              <div class="min-w-0 flex-1">
                <div class="text-sm font-bold">{s.label}</div>
                <p class="mt-0.5 text-[13px] leading-relaxed text-muted">{s.description}</p>
                <p :if={inactive?(s, @values)} class="mt-1 text-xs text-subtle">
                  Applies only when {label_for(s.depends_on)} is on.
                </p>
                <p :if={s.changed} class="mt-1.5 text-xs text-subtle">
                  Last changed by {(s.changed.updated_by && s.changed.updated_by.name) || "—"} · {Knra.Time.format(
                    s.changed.updated_at
                  )}
                </p>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={to_string(s.value)}
                aria-label={s.label}
                id={"toggle-#{s.key}"}
                phx-click="toggle"
                phx-value-key={s.key}
                data-confirm={confirm_text(s)}
                data-confirm-title={
                  if s.value, do: "Turn Off: #{s.label}", else: "Turn On: #{s.label}"
                }
                data-confirm-button={if s.value, do: "Turn Off", else: "Turn On"}
                data-confirm-variant={
                  if Map.get(s, :risky, false) and not s.value, do: "danger", else: "primary"
                }
                class={[
                  "relative mt-0.5 inline-flex h-6 w-11 flex-none cursor-pointer items-center rounded-full transition-colors",
                  if(s.value, do: "bg-ok", else: "bg-[#c9d1d8]")
                ]}
              >
                <span class={[
                  "inline-block size-5 rounded-full bg-white shadow transition-transform",
                  if(s.value, do: "translate-x-5.5", else: "translate-x-0.5")
                ]}>
                </span>
              </button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Settings.subscribe()
    {:ok, socket |> assign(:page_title, "System Settings") |> load()}
  end

  @impl true
  def handle_event("toggle", %{"key" => key}, socket) do
    current = Map.fetch!(socket.assigns.values, key)

    case Settings.put(socket.assigns.current_scope, key, not current) do
      {:ok, value} ->
        label = Enum.find(Settings.definitions(), &(&1.key == key)).label

        {:noreply,
         socket |> put_flash(:info, "#{label}: #{if value, do: "on", else: "off"}.") |> load()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Your role cannot change system settings.")}
    end
  end

  @impl true
  def handle_info(:settings_changed, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    settings = Settings.list()

    assign(socket,
      groups: settings |> Enum.chunk_by(& &1.group) |> Enum.map(&{hd(&1).group, &1}),
      values: Map.new(settings, &{&1.key, &1.value})
    )
  end

  defp inactive?(%{depends_on: dep}, values), do: not Map.get(values, dep, false)
  defp inactive?(_, _), do: false

  defp label_for(key), do: Enum.find(Settings.definitions(), &(&1.key == key)).label

  defp confirm_text(%{key: "auto_clear_no_alarm", value: false}),
    do:
      "No-alarm passes will be approved without a screening report or verification, and certificates issued automatically. Continue?"

  defp confirm_text(%{key: "auto_clear_wait_for_payment", value: true}),
    do:
      "Auto-approved containers will be cleared and certified before the screening fee is paid. Continue?"

  defp confirm_text(%{key: "rpm_override_enabled", value: true}),
    do:
      "RPM operators will no longer be able to record passes that KenTrade cannot confirm. Continue?"

  defp confirm_text(%{label: label, value: value}),
    do: "#{if value, do: "Turn off", else: "Turn on"} \"#{label}\"?"
end
