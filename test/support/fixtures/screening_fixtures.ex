defmodule Knra.ScreeningFixtures do
  @moduledoc "Lanes, fee schedule and staff of every role for workflow tests."

  import Knra.AccountsFixtures

  alias Knra.Repo
  alias Knra.Accounts.Scope
  alias Knra.Billing.{FeeItem, FeeSchedule}
  alias Knra.Devices.Lane

  def setup_screening(_context \\ %{}) do
    lane1 =
      Repo.insert!(%Lane{
        name: "Lane 1",
        device_code: "RPM-T-01",
        serial_number: "SN-1",
        detector_type: "PVT",
        calibration_due_on: ~D[2030-01-01]
      })

    lane2 =
      Repo.insert!(%Lane{
        name: "Lane 2",
        device_code: "RPM-T-02",
        serial_number: "SN-2",
        detector_type: "PVT",
        in_service: false,
        status_reason: "fault"
      })

    scopes =
      for role <- ~w(cas_operator field_officer checking_officer verification_officer supervisor),
          into: %{} do
        {String.to_atom(role), Scope.for_user(user_fixture(%{role: role, name: role}))}
      end

    schedule =
      Repo.insert!(%FeeSchedule{
        version: 1,
        effective_from: ~D[2026-01-01],
        status: "approved",
        note: "test",
        created_by_id: scopes.supervisor.user.id,
        approved_at: DateTime.utc_now(:second)
      })

    Repo.insert!(%FeeItem{
      fee_schedule_id: schedule.id,
      code: "screening",
      description: "Containerised cargo screening",
      amount_usd: Decimal.new("20.00"),
      amount_kes: Decimal.new("2600.00")
    })

    Map.merge(scopes, %{lane: lane1, faulty_lane: lane2, schedule: schedule})
  end

  @doc "Ingests an RPM occupancy on the in-service test lane."
  def rpm_pass(container, alarmed \\ false) do
    {:ok, app} =
      Knra.Screening.ingest_occupancy(%{
        occupancy_ref: "OCC-#{System.unique_integer([:positive])}",
        container_number: container,
        lane_code: "RPM-T-01",
        gamma_cps: if(alarmed, do: 180, else: 40),
        neutron_cps: 2,
        alarmed: alarmed
      })

    Knra.Screening.get_application!(app.reference)
  end

  def reload(app), do: Knra.Screening.get_application!(app.reference)

  def mpesa(invoice_number, amount \\ "2600") do
    Knra.Billing.record_mpesa_confirmation(%{
      "TransID" => "T#{System.unique_integer([:positive])}",
      "TransAmount" => amount,
      "BillRefNumber" => invoice_number,
      "MSISDN" => "254712345678",
      "TransTime" => "20260928101500"
    })
  end
end
