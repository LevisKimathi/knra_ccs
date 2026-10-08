defmodule Knra.Simulator do
  @moduledoc """
  Development / sandbox stand-ins for the RPM hardware feed and the M-Pesa
  Paybill confirmation callback. Both drive the same code paths the real
  integrations will use (`Knra.Screening.ingest_occupancy/1` and
  `Knra.Billing.record_mpesa_confirmation/1`).

  Only available when `config :knra, :simulators_enabled` is true.
  """

  alias Knra.{Billing, Devices, Screening}
  alias Knra.Accounts.Policy

  @gamma_threshold 100

  def enabled?, do: Application.get_env(:knra, :simulators_enabled, false)

  @doc """
  Simulates a container passing an RPM. `lane_code` of `"auto"` picks an
  in-service lane. `alarm?` forces a gamma alarm; otherwise counts stay near
  background.
  """
  def rpm_pass(scope, container_number, lane_code, alarm?, opts \\ []) do
    with :ok <- check(scope),
         {:ok, lane_code} <- pick_lane(lane_code) do
      gamma =
        if alarm?, do: @gamma_threshold + 20 + :rand.uniform(90), else: 30 + :rand.uniform(15)

      neutron = if alarm?, do: 3, else: 1 + :rand.uniform(2)
      now = Knra.Time.now()
      local = Knra.Time.to_local(now)

      Screening.ingest_occupancy(
        %{
          occupancy_ref:
            "OCC-#{Calendar.strftime(local, "%y%m%d%H%M%S")}-#{:rand.uniform(899) + 100}",
          container_number: container_number,
          lane_code: lane_code,
          scanned_at: now,
          gamma_cps: gamma,
          neutron_cps: neutron,
          alarmed: gamma > @gamma_threshold or neutron > 5
        },
        Keyword.take(opts, [:lookup])
      )
    end
  end

  @doc "Simulates the importer paying an invoice through the M-Pesa Paybill."
  def mpesa_payment(scope, account_reference, amount_kes, msisdn) do
    with :ok <- check(scope) do
      local = Knra.Time.to_local(Knra.Time.now())

      Billing.record_mpesa_confirmation(%{
        "TransactionType" => "Pay Bill",
        "TransID" =>
          "S" <>
            (:crypto.strong_rand_bytes(6) |> Base.encode32(padding: false) |> binary_part(0, 9)),
        "TransTime" => Calendar.strftime(local, "%Y%m%d%H%M%S"),
        "TransAmount" => to_string(amount_kes),
        "BusinessShortCode" => "222222",
        "BillRefNumber" => account_reference,
        "MSISDN" => msisdn,
        "FirstName" => "SIMULATED"
      })
    end
  end

  defp check(scope) do
    cond do
      not enabled?() -> {:error, :simulators_disabled}
      not Policy.can?(scope, :simulate) -> {:error, :unauthorized}
      true -> :ok
    end
  end

  defp pick_lane("auto") do
    case Devices.list_in_service_lanes() do
      [] -> {:error, :lane_out_of_service}
      lanes -> {:ok, Enum.random(lanes).device_code}
    end
  end

  defp pick_lane(code), do: {:ok, code}

  @doc "Sample container numbers known to the KenTrade mock."
  def sample_containers do
    Map.keys(Knra.Integrations.KenTrade.MockPlug.catalogue()) ++
      Knra.Integrations.KenTrade.MockPlug.transit_containers() ++ ["ABCU1234560"]
  end
end
