defmodule KnraWeb.DocumentHTML do
  use KnraWeb, :html

  alias Knra.Screening.Application

  embed_templates "document_html/*"

  attr :back, :string, required: true
  slot :inner_block, required: true

  def sheet(assigns) do
    ~H"""
    <div class="mx-auto max-w-[840px] px-4 py-8 print:p-0">
      <div class="noprint mb-4 flex items-center gap-3">
        <.link navigate={@back} class="text-[13px] font-semibold text-brand">
          ← Back to application
        </.link>
        <div class="flex-1"></div>
        <button type="button" data-print class={btn(:primary)}>
          <.icon name="hero-printer" class="size-4" /> Download / print PDF
        </button>
      </div>
      <div class="print-sheet border border-line bg-white px-6 py-10 sm:px-[60px] sm:py-14">
        <div class="flex items-center gap-4 border-b-2 border-brand pb-5">
          <img
            src={~p"/images/knra-logo.jpeg"}
            alt="Kenya Nuclear Regulatory Authority"
            class="block h-[54px]"
          />
          <div class="h-11 w-px bg-line"></div>
          <div class="text-sm font-semibold text-muted">Containerised Cargo Screening System</div>
        </div>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  def container(number), do: Application.display_container(number)
end
