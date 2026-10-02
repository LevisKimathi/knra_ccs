defmodule KnraWeb.DocumentController do
  @moduledoc """
  Printable documents (invoice, certificate — print to PDF from the browser),
  inspection photos and the audit CSV export. All require a logged-in user with
  the relevant permission.
  """
  use KnraWeb, :controller

  alias Knra.{Audit, Screening}
  alias Knra.Accounts.Policy

  plug :authorize, :print_documents when action in [:invoice, :certificate, :photo]
  plug :authorize, :view_audit when action in [:audit_export]

  def invoice(conn, %{"ref" => ref}) do
    app = Screening.get_application!(ref)

    if app.invoice do
      render(conn, :invoice, app: app, invoice: app.invoice, page_title: app.invoice.number)
    else
      conn
      |> put_flash(:error, "No invoice has been raised.")
      |> redirect(to: ~p"/applications/#{ref}")
    end
  end

  def certificate(conn, %{"ref" => ref}) do
    app = Screening.get_application!(ref)

    if app.stage == "cleared" do
      report = Enum.find(app.reports, &(&1.status == "approved"))
      render(conn, :certificate, app: app, report: report, page_title: app.certificate_number)
    else
      conn
      |> put_flash(
        :error,
        "The certificate is issued once the report is approved and the fee is paid."
      )
      |> redirect(to: ~p"/applications/#{ref}")
    end
  end

  def photo(conn, %{"ref" => ref, "file" => file}) do
    app = Screening.get_application!(ref)
    photos = ((app.inspection && app.inspection.photos) || []) ++ app.evidence_photos

    # Only files recorded on this application (inspection or RPM evidence) are served.
    if file in photos do
      path = Path.join([Application.fetch_env!(:knra, :uploads_dir), app.reference, file])

      conn
      |> put_resp_content_type(MIME.from_path(file))
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "Not found")
    end
  end

  def audit_export(conn, params) do
    entries = Audit.search(Map.take(params, ~w(q actor object_type from to)), 100_000)

    Audit.log(
      conn.assigns.current_scope,
      :audit,
      "export",
      "Audit trail exported",
      "#{length(entries)} entries"
    )

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="knra-ccs-audit-#{Date.to_iso8601(Knra.Time.today())}.csv")
    )
    |> send_resp(200, Audit.to_csv(entries))
  end

  defp authorize(conn, permission) do
    if Policy.can?(conn.assigns.current_scope, permission) do
      conn
    else
      conn
      |> put_flash(:error, "Your role does not have access to that document.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end
end
