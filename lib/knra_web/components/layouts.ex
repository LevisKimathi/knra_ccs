defmodule KnraWeb.Layouts do
  @moduledoc """
  Application shell: KNRA header, role-based left rail and the flash/toast area.
  """
  use KnraWeb, :html

  alias Knra.Accounts.{Policy, User}

  embed_templates "layouts/*"

  @doc """
  The authenticated application shell.

      <Layouts.app flash={@flash} current_scope={@current_scope} nav_counts={@nav_counts} active="lanes">
        ...
      </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :nav_counts, :map, default: %{}
  attr :active, :string, default: nil, doc: "key of the highlighted nav item"
  attr :wide, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav, nav_items(assigns.current_scope))

    ~H"""
    <div class="flex min-h-screen flex-col">
      <header class="noprint sticky top-0 z-30 flex h-16 flex-none items-center gap-4 bg-brand px-4 text-white sm:px-5">
        <button
          type="button"
          class="rounded p-1.5 hover:bg-white/15 lg:hidden"
          phx-click={JS.toggle_class("max-lg:hidden", to: "#side-nav")}
          aria-label="Menu"
        >
          <.icon name="hero-bars-3" class="size-6" />
        </button>
        <.link navigate={~p"/"} class="flex items-center gap-3.5">
          <span class="flex items-center rounded bg-white px-2.5 py-1">
            <img
              src={~p"/images/knra-logo.jpeg"}
              alt="Kenya Nuclear Regulatory Authority"
              class="block h-[30px]"
            />
          </span>
          <span class="hidden h-[30px] w-px bg-white/40 sm:block"></span>
          <span class="hidden text-sm font-semibold sm:block">
            Containerised Cargo Screening System
          </span>
        </.link>
        <div class="flex-1"></div>
        <div :if={@current_scope} class="flex items-center gap-3 text-xs">
          <span class="hidden md:inline">Port of Mombasa</span>
          <span class="hidden opacity-50 md:inline">|</span>
          <span class="font-semibold">{@current_scope.user.name}</span>
          <span class="hidden sm:inline">{User.role_label(@current_scope.user.role)}</span>
          <.link
            href={~p"/users/settings"}
            class="ml-2 rounded border border-white/40 px-2.5 py-1.5 font-semibold hover:bg-white/15"
          >
            Settings
          </.link>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="rounded border border-white/40 px-2.5 py-1.5 font-semibold hover:bg-white/15"
          >
            Log out
          </.link>
        </div>
      </header>

      <div class="flex min-h-0 flex-1">
        <nav
          :if={@current_scope}
          id="side-nav"
          class="noprint w-[236px] flex-none border-r border-line bg-white py-4 max-lg:fixed max-lg:inset-y-16 max-lg:left-0 max-lg:z-20 max-lg:hidden max-lg:shadow-xl"
        >
          <div :for={{section, items} <- @nav} :if={items != []} class="mb-3">
            <div class="px-4 pb-2 text-[11px] font-bold uppercase tracking-[0.08em] text-subtle">
              {section}
            </div>
            <.link
              :for={item <- items}
              navigate={item.path}
              class={[
                "flex items-center justify-between gap-2 border-l-[3px] px-4 py-2.5 text-[13px] transition-colors",
                if(@active == item.key,
                  do: "border-brand bg-brand-soft font-semibold text-brand",
                  else: "border-transparent text-ink hover:bg-panel"
                )
              ]}
            >
              <span>{item.label}</span>
              <span
                :if={(@nav_counts[item.key] || 0) > 0}
                class={[
                  "min-w-5 rounded-full px-1.5 py-px text-center text-[11px] font-bold",
                  if(item.key in ["alarms", "payments"],
                    do: "bg-bad-soft text-bad",
                    else: "bg-canvas text-muted"
                  )
                ]}
              >
                {@nav_counts[item.key]}
              </span>
            </.link>
          </div>
        </nav>

        <main class={["min-w-0 flex-1 px-4 pt-6 pb-16 sm:px-8 sm:pt-7"]}>
          <div class={[if(@wide, do: "max-w-[1400px]", else: "max-w-[1240px]")]}>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp nav_items(nil), do: []

  defp nav_items(scope) do
    role = scope.user.role
    can = &Policy.can?(scope, &1)

    work =
      case role do
        "cas_operator" ->
          [
            item("lanes", "Lane overview", ~p"/cas/lanes"),
            item("alarms", "Alarm queue", ~p"/cas/alarms")
          ]

        "field_officer" ->
          [item("inspections", "My inspections", ~p"/inspections")]

        r when r in ["checking_officer", "verification_officer"] ->
          [item("reports", "Screening reports", ~p"/reports")]

        "supervisor" ->
          [
            item("lanes", "Lane overview", ~p"/cas/lanes"),
            item("alarms", "Alarm queue", ~p"/cas/alarms"),
            item("reports", "Screening reports", ~p"/reports")
          ]

        "super_admin" ->
          [
            item("lanes", "Lane overview", ~p"/cas/lanes"),
            item("alarms", "Alarm queue", ~p"/cas/alarms"),
            item("inspections", "Secondary inspections", ~p"/inspections"),
            item("reports", "Screening reports", ~p"/reports")
          ]

        _ ->
          []
      end

    work = work ++ [item("applications", "All applications", ~p"/applications")]

    admin =
      [
        can.(:manage_devices) && item("devices", "RPM devices", ~p"/admin/devices"),
        can.(:manage_users) && item("users", "Users & roles", ~p"/admin/users"),
        can.(:manage_fees) && item("fees", "Fee schedule", ~p"/admin/fees"),
        can.(:reconcile_payments) && item("payments", "Payments", ~p"/admin/payments"),
        can.(:view_audit) && item("audit", "Audit trail", ~p"/admin/audit"),
        can.(:view_integrations) && item("integrations", "Integrations", ~p"/admin/integrations")
      ]
      |> Enum.filter(& &1)

    tools =
      if Knra.Simulator.enabled?() and can.(:simulate),
        do: [item("simulator", "RPM & M-Pesa simulator", ~p"/simulator")],
        else: []

    [{"Screens", work}, {"Administration", admin}, {"Sandbox", tools}]
  end

  defp item(key, label, path), do: %{key: key, label: label, path: path}

  @doc "Centered card layout for login and account pages."
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col">
      <header class="flex h-16 flex-none items-center gap-3.5 bg-brand px-5 text-white">
        <.link navigate={~p"/"} class="flex items-center gap-3.5">
          <span class="flex items-center rounded bg-white px-2.5 py-1">
            <img
              src={~p"/images/knra-logo.jpeg"}
              alt="Kenya Nuclear Regulatory Authority"
              class="block h-[30px]"
            />
          </span>
          <span class="text-sm font-semibold">Containerised Cargo Screening System</span>
        </.link>
        <div class="flex-1"></div>
        <.link :if={@current_scope} href={~p"/"} class="text-xs font-semibold hover:underline">
          Back to the system →
        </.link>
      </header>
      <main class="flex flex-1 items-start justify-center px-4 py-12">
        <div class="w-full max-w-md rounded-md border border-line bg-white p-8 shadow-sm">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="noprint">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
