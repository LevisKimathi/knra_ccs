defmodule Knra.ScreeningTest do
  use Knra.DataCase, async: false

  import Knra.ScreeningFixtures

  alias Knra.{Audit, Billing, Screening}

  setup :setup_screening

  @narrative %{"narrative" => "Clear pass, counts within background. No objection."}

  describe "RPM occupancy" do
    test "clear pass opens an application, raises an invoice and fetches KenTrade data" do
      app = rpm_pass("MSKU 774-1293")

      assert app.container_number == "MSKU7741293"
      assert app.stage == "report_draft"
      assert app.lookup_status == "found"
      assert app.importer_name == "RIFT VALLEY MOTORS LTD"
      assert app.hs_code == "87082900"
      assert app.invoice.status == "pending"
      assert Decimal.equal?(app.invoice.amount_kes, Decimal.new("2600"))
      assert app.reference =~ ~r/^CCS-\d{4}-\d{6}$/
    end

    test "alarm pass goes to the alarm queue" do
      app = rpm_pass("TGHU5029184", true)
      assert app.stage == "alarm"
      assert [%{reference: ref}] = Screening.list_by_stage("alarm")
      assert ref == app.reference
    end

    test "is idempotent on occupancy reference" do
      event = %{
        occupancy_ref: "OCC-1",
        container_number: "MSKU7741293",
        lane_code: "RPM-T-01",
        gamma_cps: 40,
        neutron_cps: 1,
        alarmed: false
      }

      {:ok, a} = Screening.ingest_occupancy(event)
      {:ok, b} = Screening.ingest_occupancy(event)
      assert a.id == b.id
    end

    test "rejects bad container numbers, faulty lanes and containers already in screening" do
      base = %{
        occupancy_ref: "OCC-X",
        lane_code: "RPM-T-01",
        gamma_cps: 40,
        neutron_cps: 1,
        alarmed: false
      }

      assert {:error, :invalid_container_number} =
               Screening.ingest_occupancy(Map.put(base, :container_number, "12345"))

      assert {:error, :lane_out_of_service} =
               Screening.ingest_occupancy(
                 %{base | lane_code: "RPM-T-02"}
                 |> Map.put(:container_number, "MSKU7741293")
               )

      rpm_pass("MSKU7741293")

      assert {:error, :already_in_screening} =
               Screening.ingest_occupancy(
                 %{base | occupancy_ref: "OCC-Y"}
                 |> Map.put(:container_number, "MSKU7741293")
               )
    end

    test "records KenTrade NOT_FOUND and TRANSIT without blocking screening" do
      assert rpm_pass("ABCU1234560").lookup_status == "not_found"
      assert rpm_pass("TRLU9001234").lookup_status == "transit"
      assert rpm_pass("ERRU0000000").lookup_status == "error"
    end
  end

  describe "CAS adjudication" do
    test "requires the CAS role, a classification and a reason", %{
      cas_operator: cas,
      field_officer: field
    } do
      app = rpm_pass("TGHU5029184", true)

      assert {:error, :unauthorized} =
               Screening.adjudicate(field, app, %{
                 "decision" => "release",
                 "classification" => "NORM (naturally occurring)",
                 "reason" => "Looks fine to me"
               })

      assert {:error, %Ecto.Changeset{} = cs} =
               Screening.adjudicate(cas, app, %{"decision" => "release", "reason" => ""})

      assert %{reason: [_ | _], classification: [_ | _]} = errors_on(cs)
      assert reload(app).stage == "alarm"
    end

    test "release, divert and detain move the stage", %{cas_operator: cas} do
      params =
        &%{
          "decision" => &1,
          "classification" => "NORM (naturally occurring)",
          "reason" => "Reason for the decision"
        }

      assert {:ok, %{stage: "report_draft"}} =
               Screening.adjudicate(cas, rpm_pass("TGHU5029184", true), params.("release"))

      assert {:ok, %{stage: "secondary"}} =
               Screening.adjudicate(cas, rpm_pass("CMAU1187640", true), params.("secondary"))

      assert {:ok, %{stage: "detained"}} =
               Screening.adjudicate(cas, rpm_pass("PONU3345671", true), params.("detain"))
    end

    test "cannot adjudicate twice", %{cas_operator: cas} do
      app = rpm_pass("TGHU5029184", true)

      params = %{
        "decision" => "release",
        "classification" => "NORM (naturally occurring)",
        "reason" => "Reason for the decision"
      }

      assert {:ok, _} = Screening.adjudicate(cas, app, params)
      assert {:error, {:invalid_stage, "report_draft"}} = Screening.adjudicate(cas, app, params)
    end
  end

  describe "field inspection" do
    test "no objection returns the application to report drafting", %{
      cas_operator: cas,
      field_officer: field
    } do
      app = rpm_pass("CMAU1187640", true)

      {:ok, _} =
        Screening.adjudicate(cas, app, %{
          "decision" => "secondary",
          "classification" => "Unresolved — requires secondary",
          "reason" => "Needs handheld check"
        })

      assert {:error, %Ecto.Changeset{}} =
               Screening.submit_inspection(field, app, %{
                 "isotope" => "K-40 (NORM)",
                 "dose_rate_usv_h" => "0.2",
                 "findings" => "",
                 "outcome" => "no_objection"
               })

      assert {:ok, %{stage: "report_draft"}} =
               Screening.submit_inspection(
                 field,
                 app,
                 %{
                   "isotope" => "K-40 (NORM)",
                   "dose_rate_usv_h" => "0.2",
                   "findings" => "NORM in clinker, packaging intact",
                   "outcome" => "no_objection"
                 },
                 ["a.jpg"]
               )

      assert reload(app).inspection.photos == ["a.jpg"]
    end
  end

  describe "maker–checker and clearance" do
    test "approved report plus paid invoice clears and issues a certificate", ctx do
      app = rpm_pass("MSKU7741293")

      assert {:error, :unauthorized} =
               Screening.submit_report(ctx.verification_officer, app, @narrative)

      assert {:ok, %{stage: "report_check"}} =
               Screening.submit_report(ctx.checking_officer, app, @narrative)

      assert {:error, :unauthorized} = Screening.approve_report(ctx.checking_officer, app)
      assert {:ok, %{stage: "approved"}} = Screening.approve_report(ctx.verification_officer, app)

      app = reload(app)
      assert {:ok, %{status: "matched"}} = mpesa(app.invoice.number)

      app = reload(app)
      assert app.stage == "cleared"
      assert app.invoice.status == "paid"
      assert app.certificate_number =~ ~r|^KNRA/CCS/\d{4}/\d{6}$|
    end

    test "payment before approval clears on approval", ctx do
      app = rpm_pass("MSKU7741293")
      {:ok, _} = mpesa(app.invoice.number)
      assert reload(app).stage == "report_draft"

      {:ok, _} = Screening.submit_report(ctx.checking_officer, app, @narrative)
      assert {:ok, %{stage: "cleared"}} = Screening.approve_report(ctx.verification_officer, app)
    end

    test "a part payment does not clear", ctx do
      app = rpm_pass("MSKU7741293")
      {:ok, _} = Screening.submit_report(ctx.checking_officer, app, @narrative)
      {:ok, _} = Screening.approve_report(ctx.verification_officer, app)
      {:ok, _} = mpesa(app.invoice.number, "1000")
      assert reload(app).stage == "approved"
      {:ok, _} = mpesa(app.invoice.number, "1600")
      assert reload(app).stage == "cleared"
    end

    test "rejection needs a reason and returns the report to the maker", ctx do
      app = rpm_pass("MSKU7741293")
      {:ok, _} = Screening.submit_report(ctx.checking_officer, app, @narrative)

      assert {:error, %Ecto.Changeset{}} =
               Screening.reject_report(ctx.verification_officer, app, %{"rejection_reason" => ""})

      assert {:ok, %{stage: "report_draft"}} =
               Screening.reject_report(ctx.verification_officer, app, %{
                 "rejection_reason" => "Add the lane number"
               })

      assert [%{status: "rejected", rejection_reason: "Add the lane number"}] =
               reload(app).reports

      assert {:ok, %{stage: "report_check"}} =
               Screening.submit_report(ctx.checking_officer, app, @narrative)
    end

    test "the maker can never verify their own report, even after a role change", ctx do
      app = rpm_pass("MSKU7741293")
      {:ok, _} = Screening.submit_report(ctx.checking_officer, app, @narrative)

      maker_now_verifier =
        ctx.checking_officer.user
        |> Ecto.Changeset.change(role: "verification_officer")
        |> Knra.Repo.update!()
        |> Knra.Accounts.Scope.for_user()

      assert {:error, :segregation_of_duties} = Screening.approve_report(maker_now_verifier, app)

      assert {:error, :segregation_of_duties} =
               Screening.reject_report(maker_now_verifier, app, %{"rejection_reason" => "x"})
    end
  end

  describe "payments" do
    test "M-Pesa confirmations are idempotent and unmatched ones can be reconciled", ctx do
      app = rpm_pass("MSKU7741293")

      payload = %{
        "TransID" => "QK1",
        "TransAmount" => "2600",
        "BillRefNumber" => "WRONG-REF",
        "MSISDN" => "254700000000",
        "TransTime" => "20260928101500"
      }

      assert {:ok, %{status: "unmatched"} = p} = Billing.record_mpesa_confirmation(payload)
      assert {:ok, %{id: same}} = Billing.record_mpesa_confirmation(payload)
      assert same == p.id

      assert {:error, :unauthorized} =
               Billing.reconcile_payment(ctx.cas_operator, p, app.invoice.number)

      assert {:ok, %{status: "matched"}} =
               Billing.reconcile_payment(ctx.supervisor, p, app.invoice.number)

      assert reload(app).invoice.status == "paid"
    end

    test "bank transfers are recorded by staff", ctx do
      app = rpm_pass("MSKU7741293")

      assert {:error, :unauthorized} =
               Billing.record_bank_transfer(ctx.field_officer, app.invoice, %{
                 "reference" => "FT1",
                 "amount_kes" => "2600"
               })

      assert {:ok, _} =
               Billing.record_bank_transfer(ctx.cas_operator, app.invoice, %{
                 "reference" => "FT1",
                 "amount_kes" => "2600"
               })

      assert {:error, %Ecto.Changeset{}} =
               Billing.record_bank_transfer(ctx.cas_operator, app.invoice, %{
                 "reference" => "FT1",
                 "amount_kes" => "2600"
               })

      assert reload(app).invoice.status == "paid"
    end
  end

  describe "fee schedule" do
    test "a second supervisor must approve a proposal", ctx do
      other =
        Knra.Accounts.Scope.for_user(Knra.AccountsFixtures.user_fixture(%{role: "supervisor"}))

      tomorrow = Date.add(Knra.Time.today(), 1) |> Date.to_iso8601()

      {:ok, s} =
        Billing.propose_fee_schedule(ctx.supervisor, %{
          "effective_from" => tomorrow,
          "note" => "Gazette 1",
          "items" => %{
            "0" => %{
              "code" => "screening",
              "description" => "Screening",
              "amount_usd" => "25",
              "amount_kes" => "3250"
            }
          }
        })

      assert {:error, :segregation_of_duties} = Billing.approve_fee_schedule(ctx.supervisor, s)
      assert {:ok, %{status: "approved"}} = Billing.approve_fee_schedule(other, s)

      # Not in force until its effective date
      assert Billing.schedule_in_force().version == 1
      assert Billing.schedule_in_force(Date.add(Knra.Time.today(), 1)).version == s.version
    end
  end

  describe "audit trail" do
    test "every step is chained and the table is append-only" do
      app = rpm_pass("MSKU7741293")
      actions = app |> Screening.timeline() |> Enum.map(& &1.action)

      assert Enum.any?(actions, &(&1 =~ "read by OCR"))
      assert Enum.any?(actions, &(&1 =~ "Consignment data retrieved"))
      assert Enum.any?(actions, &(&1 =~ "Invoice"))
      assert Audit.verify_chain() == :ok

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Knra.Repo.query!("UPDATE audit_entries SET action = 'tampered'")
      end
    end
  end
end
