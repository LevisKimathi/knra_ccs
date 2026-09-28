defmodule Knra.Billing do
  @moduledoc """
  Fee schedule (M9), invoicing and payments (M6).

  An invoice is raised automatically on every RPM occupancy, priced from the fee
  schedule in force on the day of the pass. Importers pay outside the system, by
  M-Pesa Paybill (invoice number as the account reference) or by bank transfer.
  M-Pesa confirmations are matched automatically; bank transfers are confirmed by
  staff. Payments that cannot be matched wait for a supervisor to reconcile them.
  """

  import Ecto.Query

  alias Knra.{Audit, Repo}
  alias Knra.Accounts.Policy
  alias Knra.Billing.{FeeItem, FeeSchedule, Invoice, Payment}

  @mpesa_actor "M-Pesa Paybill"

  ## ------------------------------------------------------------------
  ## Fee schedule (M9)

  def list_fee_schedules do
    Repo.all(
      from s in FeeSchedule,
        order_by: [desc: s.version],
        preload: [:items, :created_by, :approved_by]
    )
  end

  def get_fee_schedule!(id),
    do: FeeSchedule |> Repo.get!(id) |> Repo.preload([:items, :created_by, :approved_by])

  @doc "The approved schedule in force on `date` (Nairobi calendar date)."
  def schedule_in_force(date \\ Knra.Time.today()) do
    Repo.one(
      from s in FeeSchedule,
        where: s.status == "approved" and s.effective_from <= ^date,
        order_by: [desc: s.effective_from, desc: s.version],
        limit: 1,
        preload: :items
    )
  end

  def fee_item(%FeeSchedule{items: items}, code), do: Enum.find(items, &(&1.code == code))

  @doc "A new proposal pre-filled from the schedule currently in force."
  def new_proposal do
    items =
      case schedule_in_force() do
        nil ->
          []

        s ->
          Enum.map(s.items, fn i ->
            %FeeItem{
              code: i.code,
              description: i.description,
              amount_usd: i.amount_usd,
              amount_kes: i.amount_kes,
              position: i.position
            }
          end)
      end

    %FeeSchedule{items: items, effective_from: Date.add(Knra.Time.today(), 1)}
  end

  def change_proposal(%FeeSchedule{} = s, attrs \\ %{}),
    do: FeeSchedule.proposal_changeset(s, attrs)

  @doc "Proposes a new fee schedule version. It takes effect only once another supervisor approves it."
  def propose_fee_schedule(scope, attrs) do
    with :ok <- Policy.authorize(scope, :manage_fees) do
      Repo.transaction(fn ->
        version = (Repo.one(from s in FeeSchedule, select: max(s.version)) || 0) + 1

        %FeeSchedule{version: version, status: "pending_approval", created_by_id: scope.user.id}
        |> FeeSchedule.proposal_changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, s} ->
            Audit.log(
              scope,
              :fee_schedule,
              "v#{version}",
              "Fee schedule v#{version} proposed",
              "Effective #{Knra.Time.format_date(s.effective_from)}. #{s.note}"
            )

            s

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
    end
  end

  @doc "Approves a pending schedule. The proposer cannot approve their own proposal (super admins excepted)."
  def approve_fee_schedule(scope, %FeeSchedule{} = s) do
    with :ok <- Policy.authorize(scope, :manage_fees),
         :ok <- pending(s),
         :ok <- not_own(scope, s),
         :ok <- not_backdated(s) do
      Repo.transaction(fn ->
        updated =
          s
          |> Ecto.Changeset.change(
            status: "approved",
            approved_by_id: scope.user.id,
            approved_at: Knra.Time.now()
          )
          |> Repo.update!()

        Audit.log(
          scope,
          :fee_schedule,
          "v#{s.version}",
          "Fee schedule v#{s.version} approved",
          ["Effective #{Knra.Time.format_date(s.effective_from)}", own_proposal_note(scope, s)]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(". ")
        )

        updated
      end)
    end
  end

  def reject_fee_schedule(scope, %FeeSchedule{} = s, reason) do
    reason = String.trim(reason || "")

    with :ok <- Policy.authorize(scope, :manage_fees),
         :ok <- pending(s),
         :ok <- not_own(scope, s),
         :ok <- if(reason == "", do: {:error, :reason_required}, else: :ok) do
      Repo.transaction(fn ->
        updated =
          s
          |> Ecto.Changeset.change(
            status: "rejected",
            approved_by_id: scope.user.id,
            approved_at: Knra.Time.now(),
            rejection_reason: reason
          )
          |> Repo.update!()

        Audit.log(
          scope,
          :fee_schedule,
          "v#{s.version}",
          "Fee schedule v#{s.version} rejected",
          [reason, own_proposal_note(scope, s)] |> Enum.reject(&is_nil/1) |> Enum.join(". ")
        )

        updated
      end)
    end
  end

  defp pending(%FeeSchedule{status: "pending_approval"}), do: :ok
  defp pending(_), do: {:error, :not_pending}

  defp not_own(scope, %FeeSchedule{created_by_id: id}) do
    if id == scope.user.id and not Policy.segregation_exempt?(scope),
      do: {:error, :segregation_of_duties},
      else: :ok
  end

  defp own_proposal_note(scope, %FeeSchedule{created_by_id: id}) when id == scope.user.id,
    do: "Proposed and decided by the same super administrator (segregation of duties overridden)"

  defp own_proposal_note(_scope, _schedule), do: nil

  defp not_backdated(%FeeSchedule{effective_from: d}) do
    if Date.compare(d, Knra.Time.today()) == :lt, do: {:error, :effective_date_passed}, else: :ok
  end

  ## ------------------------------------------------------------------
  ## Invoices

  @doc false
  # Called by Knra.Screening inside the RPM-occupancy transaction.
  def raise_invoice!(application, scanned_at) do
    date = scanned_at |> Knra.Time.to_local() |> NaiveDateTime.to_date()
    schedule = schedule_in_force(date) || raise "no approved fee schedule in force on #{date}"

    item =
      fee_item(schedule, "screening") ||
        raise "fee schedule v#{schedule.version} has no screening fee"

    number = next_number("invoice_number_seq", "INV")

    invoice =
      Repo.insert!(%Invoice{
        application_id: application.id,
        number: number,
        fee_schedule_id: schedule.id,
        description: item.description,
        amount_usd: item.amount_usd,
        amount_kes: item.amount_kes,
        status: if(Decimal.equal?(item.amount_kes, 0), do: "paid", else: "pending")
      })

    Audit.log(
      "System",
      :application,
      application.reference,
      "Invoice #{number} issued — USD #{fmt(item.amount_usd)} / KES #{fmt(item.amount_kes)} (pending)"
    )

    invoice
  end

  def get_invoice_by_number(number) do
    Invoice
    |> Repo.get_by(number: normalise_ref(number))
    |> Repo.preload([:payments, :application])
  end

  ## ------------------------------------------------------------------
  ## Payments

  @doc """
  Handles an M-Pesa Paybill (C2B) confirmation. Fields follow Safaricom's C2B
  confirmation payload: `TransID`, `TransAmount`, `BillRefNumber`, `MSISDN`,
  `TransTime` (yyyyMMddHHmmss, Nairobi time), `FirstName`.

  Idempotent on `TransID`.
  """
  def record_mpesa_confirmation(%{"TransID" => trans_id} = payload) do
    account_ref = normalise_ref(payload["BillRefNumber"])

    attrs = %{
      reference: trans_id,
      account_reference: account_ref,
      amount_kes: payload["TransAmount"],
      payer:
        [payload["FirstName"], mask_msisdn(payload["MSISDN"])]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" · "),
      received_at: parse_mpesa_time(payload["TransTime"]),
      raw: payload
    }

    Repo.get_by(Payment, method: "mpesa", reference: trans_id)
    |> case do
      %Payment{} = existing ->
        {:ok, existing}

      nil ->
        Repo.transaction(fn ->
          invoice = lock_invoice_by_number(account_ref)

          cs =
            %Payment{
              method: "mpesa",
              status: if(invoice, do: "matched", else: "unmatched"),
              invoice_id: invoice && invoice.id
            }
            |> Payment.mpesa_changeset(attrs)

          case Repo.insert(cs) do
            {:ok, payment} ->
              if invoice do
                apply_payment!(invoice, payment, @mpesa_actor <> " · " <> trans_id)
              else
                Audit.log(
                  @mpesa_actor,
                  :payment,
                  trans_id,
                  "Unmatched M-Pesa payment received",
                  "Account reference #{account_ref || "—"}, KES #{fmt(payment.amount_kes)}"
                )
              end

              payment

            {:error, cs} ->
              Repo.rollback(cs)
          end
        end)
        |> after_payment()
    end
  end

  def change_bank_payment(attrs \\ %{}), do: Payment.bank_changeset(%Payment{}, attrs)

  @doc "Staff confirmation that a bank transfer for `invoice` was received."
  def record_bank_transfer(scope, %Invoice{} = invoice, attrs) do
    with :ok <- Policy.authorize(scope, :record_payment) do
      Repo.transaction(fn ->
        invoice = Repo.get!(Invoice, invoice.id, lock: "FOR UPDATE")

        %Payment{
          method: "bank",
          status: "matched",
          invoice_id: invoice.id,
          recorded_by_id: scope.user.id,
          received_at: Knra.Time.now(),
          account_reference: invoice.number
        }
        |> Payment.bank_changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, payment} ->
            apply_payment!(invoice, payment, scope)
            payment

          {:error, cs} ->
            Repo.rollback(cs)
        end
      end)
      |> after_payment()
    end
  end

  def list_unmatched_payments do
    Repo.all(from p in Payment, where: p.status == "unmatched", order_by: [desc: p.received_at])
  end

  def count_unmatched_payments,
    do: Repo.aggregate(from(p in Payment, where: p.status == "unmatched"), :count)

  @doc "Supervisor applies an unmatched payment to an invoice."
  def reconcile_payment(scope, %Payment{status: "unmatched"} = payment, invoice_number) do
    with :ok <- Policy.authorize(scope, :reconcile_payments) do
      Repo.transaction(fn ->
        case lock_invoice_by_number(normalise_ref(invoice_number)) do
          nil ->
            Repo.rollback(:invoice_not_found)

          invoice ->
            payment =
              payment
              |> Ecto.Changeset.change(
                status: "matched",
                invoice_id: invoice.id,
                recorded_by_id: scope.user.id
              )
              |> Repo.update!()

            Audit.log(
              scope,
              :payment,
              payment.reference,
              "Payment reconciled to #{invoice.number}"
            )

            apply_payment!(invoice, payment, scope)
            payment
        end
      end)
      |> after_payment()
    end
  end

  def reconcile_payment(_scope, _payment, _number), do: {:error, :not_unmatched}

  # Adds the payment to the invoice timeline and marks the invoice paid once the
  # amount received covers the invoice.
  defp apply_payment!(%Invoice{} = invoice, %Payment{} = payment, actor) do
    invoice = Repo.preload(invoice, [:application, :payments], force: true)
    received = Invoice.amount_received(invoice)
    app_ref = invoice.application.reference

    Audit.log(
      actor,
      :application,
      app_ref,
      "#{Payment.method_label(payment.method)} payment received — KES #{fmt(payment.amount_kes)}",
      "Reference #{payment.reference} against #{invoice.number}"
    )

    if invoice.status == "pending" and Decimal.compare(received, invoice.amount_kes) != :lt do
      invoice |> Ecto.Changeset.change(status: "paid", paid_at: Knra.Time.now()) |> Repo.update!()
      Audit.log("System", :application, app_ref, "Invoice #{invoice.number} paid in full")
    end
  end

  defp after_payment({:ok, %Payment{invoice_id: nil}} = res), do: res

  defp after_payment({:ok, %Payment{invoice_id: invoice_id}} = res) do
    invoice = Repo.get!(Invoice, invoice_id)
    Knra.Screening.invoice_paid(invoice.application_id)
    res
  end

  defp after_payment(other), do: other

  defp lock_invoice_by_number(nil), do: nil

  defp lock_invoice_by_number(number) do
    Repo.one(from i in Invoice, where: i.number == ^number, lock: "FOR UPDATE")
  end

  ## ------------------------------------------------------------------
  ## Helpers

  @doc false
  def next_number(sequence, prefix) do
    %{rows: [[n]]} = Repo.query!("SELECT nextval('#{sequence}')")
    "#{prefix}-#{Knra.Time.year()}-#{n |> Integer.to_string() |> String.pad_leading(6, "0")}"
  end

  def normalise_ref(nil), do: nil
  def normalise_ref(ref), do: ref |> to_string() |> String.trim() |> String.upcase()

  @doc "Formats a decimal as `2,600.00`."
  def fmt(nil), do: "—"

  def fmt(%Decimal{} = d) do
    [int, frac] =
      d
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
      |> String.split(".")
      |> then(fn
        [i] -> [i, "00"]
        [i, f] -> [i, String.pad_trailing(f, 2, "0")]
      end)

    {sign, int} =
      if String.starts_with?(int, "-"), do: {"-", String.slice(int, 1..-1//1)}, else: {"", int}

    grouped =
      int
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(",", &Enum.join/1)
      |> String.reverse()

    sign <> grouped <> "." <> frac
  end

  def fmt(n) when is_number(n), do: fmt(Decimal.new(to_string(n)))

  defp mask_msisdn(nil), do: nil

  defp mask_msisdn(m) do
    m = to_string(m)
    if String.length(m) > 6, do: String.slice(m, 0, 6) <> "***" <> String.slice(m, -3, 3), else: m
  end

  defp parse_mpesa_time(
         <<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2>>
       ) do
    with {:ok, naive} <-
           NaiveDateTime.new(
             String.to_integer(y),
             String.to_integer(mo),
             String.to_integer(d),
             String.to_integer(h),
             String.to_integer(mi),
             String.to_integer(s)
           ) do
      naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-3 * 3600, :second)
    else
      _ -> Knra.Time.now()
    end
  end

  defp parse_mpesa_time(_), do: Knra.Time.now()
end
