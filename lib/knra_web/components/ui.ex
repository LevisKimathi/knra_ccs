defmodule KnraWeb.UI do
  @moduledoc """
  KNRA CCS UI building blocks, styled after the reviewed demo.
  """
  use Phoenix.Component

  alias Knra.Screening.Application

  @doc "Tailwind classes for a button variant."
  def btn(variant \\ :primary, size \\ :md)

  def btn(variant, size) do
    base =
      "inline-flex items-center justify-center gap-1.5 rounded font-semibold transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50 phx-submit-loading:opacity-60"

    sz =
      case size do
        :sm -> "px-3 py-1.5 text-xs"
        :md -> "px-4 py-2.5 text-sm"
      end

    v =
      case variant do
        :primary ->
          "bg-brand text-white hover:bg-brand-dark"

        :outline ->
          "border border-brand bg-white text-brand hover:bg-brand hover:text-white"

        :secondary ->
          "border border-[#c9d1d8] bg-white text-ink hover:border-brand hover:text-brand"

        :ok ->
          "bg-ok text-white hover:brightness-110"

        :warn ->
          "border border-warn bg-white text-warn hover:bg-warn-soft"

        :danger ->
          "border border-bad bg-white text-bad hover:bg-bad-soft"

        :danger_solid ->
          "bg-bad text-white hover:brightness-110"

        :link ->
          "p-0 text-brand hover:text-brand-dark"
      end

    Enum.join([base, sz, v], " ")
  end

  attr :title, :string, required: true
  attr :back, :string, default: nil
  attr :back_label, :string, default: "Back"
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="mb-6">
      <.link
        :if={@back}
        navigate={@back}
        class="mb-3 inline-block text-[13px] font-semibold text-brand"
      >
        ← {@back_label}
      </.link>
      <div class="flex flex-wrap items-start gap-4">
        <div class="min-w-0 flex-1">
          <h1 class="text-2xl font-bold tracking-tight">{@title}</h1>
          <p :if={@subtitle != []} class="mt-1.5 max-w-3xl text-sm text-muted">
            {render_slot(@subtitle)}
          </p>
        </div>
        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :id, :string, default: nil
  attr :padded, :boolean, default: true
  slot :subtitle
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section id={@id} class={["rounded-md border border-line bg-white", @class]}>
      <div :if={@title} class="flex items-center gap-3 border-b border-line-soft px-5 py-3.5">
        <h2 class="text-[15px] font-bold">
          {@title}
          <span :if={@subtitle != []} class="text-[13px] font-normal text-muted">
            — {render_slot(@subtitle)}
          </span>
        </h2>
        <div class="flex-1"></div>
        {render_slot(@actions)}
      </div>
      <div class={[@padded && "p-5"]}>{render_slot(@inner_block)}</div>
    </section>
    """
  end

  attr :tone, :atom, default: :neutral, values: [:neutral, :info, :ok, :bad, :warn]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def pill(assigns) do
    ~H"""
    <span class={[
      "inline-block whitespace-nowrap rounded-full px-2.5 py-0.5 text-xs font-semibold",
      tone_class(@tone),
      @class
    ]}>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp tone_class(:neutral), do: "bg-canvas text-muted"
  defp tone_class(:info), do: "bg-brand-soft text-brand"
  defp tone_class(:ok), do: "bg-ok-soft text-ok"
  defp tone_class(:bad), do: "bg-bad-soft text-bad"
  defp tone_class(:warn), do: "bg-warn-soft text-warn"

  def stage_tone("alarm"), do: :bad
  def stage_tone("detained"), do: :bad
  def stage_tone("secondary"), do: :warn
  def stage_tone("cleared"), do: :ok
  def stage_tone("approved"), do: :ok
  def stage_tone(_), do: :info

  attr :stage, :string, required: true

  def stage_badge(assigns) do
    ~H"""
    <.pill tone={stage_tone(@stage)}>{Application.stage_label(@stage)}</.pill>
    """
  end

  attr :invoice, :any, required: true

  def invoice_badge(assigns) do
    ~H"""
    <.pill :if={@invoice} tone={if(@invoice.status == "paid", do: :ok, else: :warn)}>
      {if @invoice.status == "paid", do: "PAID", else: "PENDING"}
    </.pill>
    """
  end

  attr :number, :string, required: true
  attr :class, :any, default: nil

  def container_no(assigns) do
    ~H"""
    <span class={["font-mono font-medium", @class]}>{Application.display_container(@number)}</span>
    """
  end

  @doc "Label/value grid."
  attr :rows, :list, required: true, doc: "list of {label, value} tuples"
  attr :cols, :integer, default: 2

  def kv(assigns) do
    ~H"""
    <dl class={[
      "grid gap-x-8 gap-y-4",
      @cols == 2 && "sm:grid-cols-2",
      @cols == 3 && "sm:grid-cols-3"
    ]}>
      <div :for={{k, v} <- @rows}>
        <dt class="mb-1 text-[11px] font-bold uppercase tracking-[0.06em] text-subtle">{k}</dt>
        <dd class="text-sm break-words">{if v in [nil, ""], do: "—", else: v}</dd>
      </div>
    </dl>
    """
  end

  attr :text, :string, required: true

  def empty(assigns) do
    ~H"""
    <div class="px-5 py-6 text-[13px] text-subtle">{@text}</div>
    """
  end

  @doc "Column header row for a grid table."
  attr :cols, :string, required: true, doc: "grid-template-columns value"
  slot :inner_block, required: true

  def thead(assigns) do
    ~H"""
    <div
      class="hidden gap-3 border-b border-line bg-panel px-5 py-2.5 text-[11px] font-bold uppercase tracking-[0.06em] text-muted md:grid"
      style={"--cols: #{@cols}"}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :entries, :list, required: true

  def timeline(assigns) do
    ~H"""
    <ol class="relative">
      <li :for={{e, i} <- Enum.with_index(@entries)} class="flex gap-3.5 pb-4">
        <div class="flex flex-col items-center">
          <span class={["mt-1 size-2.5 flex-none rounded-full", event_dot(e.action)]}></span>
          <span :if={i < length(@entries) - 1} class="mt-1 w-px flex-1 bg-line"></span>
        </div>
        <div class="min-w-0 flex-1">
          <div class="text-[13px] font-semibold">{e.action}</div>
          <div class="text-xs text-muted">{e.actor_name} · {Knra.Time.format(e.inserted_at)}</div>
          <div :if={e.note} class="mt-1 text-xs text-muted">{e.note}</div>
        </div>
      </li>
    </ol>
    """
  end

  defp event_dot(action) do
    cond do
      Regex.match?(~r/alarm|detain|reject|fail|unmatched|no kentrade|out of service/i, action) ->
        "bg-bad"

      Regex.match?(
        ~r/cleared|approved|paid|complete|retrieved|received|no alarm|returned to service/i,
        action
      ) ->
        "bg-ok"

      Regex.match?(~r/secondary|awaiting|transit/i, action) ->
        "bg-warn"

      true ->
        "bg-[#c9d1d8]"
    end
  end

  @doc "Horizontal detector channel bar with the alarm threshold marker."
  attr :name, :string, required: true
  attr :value, :integer, required: true
  attr :threshold, :integer, required: true
  attr :scale, :integer, required: true

  def channel(assigns) do
    assigns =
      assigns
      |> assign(:pct, min(100, round(assigns.value * 100 / assigns.scale)))
      |> assign(:tpct, min(100, round(assigns.threshold * 100 / assigns.scale)))
      |> assign(:over, assigns.value > assigns.threshold)

    ~H"""
    <div class="mb-4">
      <div class="mb-1.5 flex justify-between text-[13px]">
        <span class="font-semibold">{@name}</span>
        <span class="font-mono text-xs text-muted">{@value} cps · threshold {@threshold} cps</span>
      </div>
      <div class="relative h-3 rounded-sm bg-canvas">
        <div
          class={["h-3 rounded-sm", if(@over, do: "bg-bad", else: "bg-ok")]}
          style={"width: #{@pct}%"}
        >
        </div>
        <div class="absolute -top-1 h-5 w-0.5 bg-ink" style={"left: #{@tpct}%"}></div>
      </div>
    </div>
    """
  end

  @doc "Short detector reading for list rows: `gamma 120 cps · neutron 3 cps`, or that none was taken."
  def counts(%{gamma_cps: nil, neutron_cps: nil}), do: "no RIID reading"

  def counts(%{gamma_cps: g, neutron_cps: n}),
    do: "gamma #{g || "—"} cps · neutron #{n || "—"} cps"

  def money(%Decimal{} = d), do: Knra.Billing.fmt(d)
  def money(nil), do: "—"
end
