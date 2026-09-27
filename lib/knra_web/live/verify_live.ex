defmodule KnraWeb.VerifyLive do
  @moduledoc "Public certificate verification — third parties check a certificate number."
  use KnraWeb, :live_view

  alias Knra.Screening
  alias Knra.Screening.Application

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <h1 class="text-xl font-bold">Verify a screening certificate</h1>
      <p class="mt-1 mb-5 text-sm text-muted">
        Enter the certificate number printed on a KNRA Radiation Screening Certificate.
      </p>
      <.form for={@form} id="verify-form" phx-submit="verify">
        <.input field={@form[:number]} placeholder="KNRA/CCS/2026/000001" />
        <button type="submit" class={[btn(:primary), "w-full"]}>Verify</button>
      </.form>

      <div
        :if={@result == :not_found}
        class="mt-5 rounded border border-bad/30 bg-bad-soft px-4 py-3 text-sm text-bad"
      >
        <strong>No certificate found</strong> with that number. The document may not be genuine.
      </div>
      <div
        :if={is_struct(@result)}
        id="verify-result"
        class="mt-5 rounded border border-ok/30 bg-ok-soft px-4 py-4 text-sm"
      >
        <div class="mb-3 font-bold text-ok">
          <.icon name="hero-check-badge" class="size-5" /> Valid certificate
        </div>
        <.kv
          cols={2}
          rows={[
            {"Certificate", @result.certificate_number},
            {"Container", Application.display_container(@result.container_number)},
            {"Screened", Knra.Time.format(@result.scanned_at)},
            {"Cleared", Knra.Time.format(@result.cleared_at)},
            {"Result", "No radiological objection"}
          ]}
        />
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Verify certificate",
        result: nil,
        form: to_form(%{"number" => params["n"] || ""}, as: :verify)
      )

    {:ok, if(params["n"], do: lookup(socket, params["n"]), else: socket)}
  end

  @impl true
  def handle_event("verify", %{"verify" => %{"number" => n}}, socket),
    do: {:noreply, lookup(socket, n)}

  defp lookup(socket, number) do
    result =
      case Screening.get_application_by_certificate(number) do
        %Application{stage: "cleared"} = app -> app
        _ -> :not_found
      end

    assign(socket, result: result, form: to_form(%{"number" => number}, as: :verify))
  end
end
