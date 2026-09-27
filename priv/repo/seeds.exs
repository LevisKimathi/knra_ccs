# Seeds the development database with KNRA staff, RPM lanes, the gazetted fee
# schedule and a handful of screening applications driven through the real
# workflow (so their audit trails are genuine).
#
#     mix run priv/repo/seeds.exs
#
# All seeded staff share the development password below. Change it (and never
# run these seeds) in any shared or production environment.

alias Knra.{Billing, Repo, Screening, Simulator}
alias Knra.Accounts.{Scope, User}
alias Knra.Billing.{FeeItem, FeeSchedule}
alias Knra.Devices.Lane

Application.put_env(:knra, :async_lookup, false)

dev_password = "knra-demo-2026!"

if Repo.aggregate(User, :count) > 0 do
  IO.puts("Database already seeded — run `mix ecto.reset` to start over.")
  System.halt(0)
end

now = DateTime.utc_now(:second)

staff = [
  {"P. Otieno", "p.otieno@knra.go.ke", "KN1001", "cas_operator", "CAS, KOT Terminal 1", "active"},
  {"B. Kiptoo", "b.kiptoo@knra.go.ke", "KN1002", "cas_operator", "CAS, KOT Terminal 1", "suspended"},
  {"S. Mwangi", "s.mwangi@knra.go.ke", "KN1101", "field_officer", "Divert bay B", "active"},
  {"A. Kimani", "a.kimani@knra.go.ke", "KN1201", "checking_officer", "KNRA Mombasa office", "active"},
  {"F. Achieng", "f.achieng@knra.go.ke", "KN1301", "verification_officer", "KNRA Mombasa office", "active"},
  {"Dr. L. Njoroge", "l.njoroge@knra.go.ke", "KN0001", "supervisor", "KNRA HQ, Nairobi", "active"},
  {"M. Wafula", "m.wafula@knra.go.ke", "KN0002", "supervisor", "KNRA Mombasa office", "active"}
]

users =
  for {name, email, staff_no, role, station, status} <- staff, into: %{} do
    user =
      %User{status: status, confirmed_at: now}
      |> User.admin_changeset(%{name: name, email: email, staff_number: staff_no, role: role, station: station})
      |> User.password_changeset(%{password: dev_password})
      |> Repo.insert!()

    {email, user}
  end

scope = fn email -> Scope.for_user(users[email]) end
cas = scope.("p.otieno@knra.go.ke")
field = scope.("s.mwangi@knra.go.ke")
maker = scope.("a.kimani@knra.go.ke")
checker = scope.("f.achieng@knra.go.ke")
supervisor = scope.("l.njoroge@knra.go.ke")

# ---- RPM lanes (M8)
for {name, code, sn, type, cal, in_service, reason} <- [
      {"Lane 1", "RPM-MSA-01", "SN 8842-114", "PVT gamma + He-3", ~D[2026-12-12], true, nil},
      {"Lane 2", "RPM-MSA-02", "SN 8842-115", "PVT gamma + He-3", ~D[2026-12-12], true, nil},
      {"Lane 3", "RPM-MSA-03", "SN 8842-116", "PVT gamma + He-3", ~D[2026-10-20], true, nil},
      {"Lane 4", "RPM-MSA-04", "SN 8842-117", "NaI spectroscopic", ~D[2027-02-02], false, "Detector fault — traffic rerouted"}
    ] do
  Repo.insert!(%Lane{
    name: name,
    device_code: code,
    serial_number: sn,
    detector_type: type,
    terminal: "KOT",
    calibration_due_on: cal,
    in_service: in_service,
    status_reason: reason
  })
end

# ---- Gazetted fee schedule v1 (M9)
schedule =
  Repo.insert!(%FeeSchedule{
    version: 1,
    effective_from: ~D[2026-07-01],
    status: "approved",
    note: "Initial gazetted schedule",
    created_by_id: users["l.njoroge@knra.go.ke"].id,
    approved_by_id: users["m.wafula@knra.go.ke"].id,
    approved_at: now
  })

for {{code, desc, usd, kes}, pos} <-
      Enum.with_index([
        {"screening", "Containerised cargo screening — per container (20ft/40ft)", "20.00", "2600.00"},
        {"rescreening", "Re-screening after failed occupancy (operator fault)", "0.00", "0.00"},
        {"secondary_inspection", "Secondary inspection at divert bay", "0.00", "0.00"},
        {"certified_copy", "Certified copy of screening certificate", "5.00", "650.00"}
      ]) do
  Repo.insert!(%FeeItem{
    fee_schedule_id: schedule.id,
    code: code,
    description: desc,
    amount_usd: Decimal.new(usd),
    amount_kes: Decimal.new(kes),
    position: pos
  })
end

Knra.Audit.log(supervisor, :fee_schedule, "v1", "Fee schedule v1 loaded", "Effective 01 Jul 2026")

# ---- Sample screening applications, driven through the workflow
ok! = fn
  {:ok, v} -> v
  other -> raise "seed step failed: #{inspect(other)}"
end

pass = fn container, lane, alarm? -> ok!.(Simulator.rpm_pass(cas, container, lane, alarm?)) end
reload = fn app -> Screening.get_application!(app.reference) end

# 1. Clear pass → report → approved → paid by M-Pesa → cleared
a1 = pass.("MSKU9930211", "RPM-MSA-02", false)
ok!.(Screening.submit_report(maker, a1, %{"narrative" => "Container passed RPM Lane 2 with no gamma or neutron alarm. Counts within background. No secondary inspection required."}))
ok!.(Screening.approve_report(checker, reload.(a1)))
inv1 = reload.(a1).invoice
ok!.(Simulator.mpesa_payment(cas, inv1.number, "2600", "254712345678"))

# 2. Gamma alarm awaiting adjudication
pass.("TGHU5029184", "RPM-MSA-01", true)

# 3. Alarm diverted to secondary inspection
a3 = pass.("CMAU1187640", "RPM-MSA-03", true)
ok!.(Screening.adjudicate(cas, reload.(a3), %{
  "decision" => "secondary",
  "classification" => "Unresolved — requires secondary",
  "reason" => "Gamma profile consistent with NORM in clinker but ratio outside the historical band for this importer. Handheld confirmation required before release."
}))

# 4. Clear pass, report awaiting verification
a4 = pass.("HLXU2288119", "RPM-MSA-02", false)
ok!.(Screening.submit_report(maker, a4, %{"narrative" => "Container passed RPM Lane 2 with no gamma or neutron alarm. Counts within background. No secondary inspection required."}))

# 5. Alarm → detained and escalated
a5 = pass.("PONU3345671", "RPM-MSA-01", true)
ok!.(Screening.adjudicate(cas, reload.(a5), %{
  "decision" => "detain",
  "classification" => "Suspected threat material",
  "reason" => "Cs-137 signature localised to the rear third of the container. Declared as ferrous scrap with no declared sources. Escalated to supervisor and national point of contact."
}))

# 6. Clear pass, report not yet drafted; bank transfer recorded
a6 = pass.("MRKU8891004", "RPM-MSA-01", false)
ok!.(Billing.record_bank_transfer(cas, reload.(a6).invoice, %{"reference" => "KCB-FT-26091877", "amount_kes" => "2600", "payer" => "Mombasa Grain Traders Ltd"}))

# An M-Pesa payment with a mistyped account number, waiting for reconciliation
ok!.(Simulator.mpesa_payment(cas, "INV-2026-00O004", "2600", "254722000111"))

IO.puts("""

Seeded #{map_size(users)} users, 4 lanes, fee schedule v1 and 6 screening applications.
Log in at http://localhost:4000/users/log-in with any seeded email (see this file).
""")
