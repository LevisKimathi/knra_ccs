# KNRA Containerised Cargo Screening System (CCS)

Phoenix LiveView application for the Kenya Nuclear Regulatory Authority's radiation
screening of containerised cargo at the Port of Mombasa. It implements modules
M1–M11 of the *CCS Module Scope & Billing Proposal*, following the reviewed UI demo.

## Workflow

```
RPM pass (OCR container no.) ─► KenTrade container enquiry ─► invoice raised
        │
        ├─ no alarm ─────────────────────────────► report_draft
        └─ alarm ─► CAS adjudication ─┬─ release ─► report_draft
                                      ├─ divert ──► secondary ─► field inspection ─┬─► report_draft
                                      │                                            └─► detained
                                      └─ detain ──► detained
report_draft ─► checking officer submits ─► report_check
report_check ─► verification officer approves ─► approved ──(invoice paid)──► cleared + certificate
             └─ rejects with reason ─► report_draft
```

Importers pay outside the system: M-Pesa Paybill (invoice number as account number,
matched automatically) or bank transfer (confirmed by staff). Unmatched M-Pesa payments
wait for a supervisor to reconcile them.

## Modules

| Proposal | Code |
|---|---|
| M1 Staff, users & roles | `Knra.Accounts`, `Knra.Accounts.Policy`, `KnraWeb.Admin.UsersLive` |
| M2 KenTrade integration | `Knra.Integrations.KenTrade` (+ `MockPlug`), `Knra.Integrations`, `KnraWeb.Admin.IntegrationsLive` |
| M3 CAS operations | `Knra.Screening` (occupancy, adjudication), `LanesLive`, `AlarmQueueLive`, `ApplicationLive.Show` |
| M4 Field inspection | `Knra.Screening.submit_inspection/4`, `InspectionsLive` (mobile-first, photo uploads) |
| M5 Maker–checker | `Knra.Screening.submit_report/3`, `approve_report/2`, `reject_report/3`, `ReportsLive` |
| M6 Payments & invoicing | `Knra.Billing` (invoices, M-Pesa C2B, bank transfers, reconciliation), `Admin.PaymentsLive` |
| M7 Certificates & documents | `KnraWeb.DocumentController` (print-to-PDF invoice & certificate), `VerifyLive` (public `/verify`) |
| M8 RPM devices & lanes | `Knra.Devices`, `Admin.DevicesLive` |
| M9 Fee schedule | `Knra.Billing` fee schedules (versioned, approved by a second supervisor), `Admin.FeesLive` |
| M10 Audit trail | `Knra.Audit` (append-only, hash-chained, DB trigger blocks UPDATE/DELETE), `Admin.AuditLive`, CSV export |
| M11 Notifications | `Knra.Notifications` (in-app toasts per role via PubSub, supervisor emails), `KnraWeb.LiveHooks` |
| Sandbox | `Knra.Simulator` + `SimulatorLive` — simulated RPM passes and M-Pesa Paybill confirmations |

## Roles

One role per user: **CAS operator**, **field inspection officer**, **checking officer**,
**verification officer**, **supervisor / administrator**. Permissions are in
`Knra.Accounts.Policy` and enforced inside every context function (not just the UI).
The officer who drafted a report can never verify it, even if their role later changes.

There is no self-registration. A supervisor creates accounts under *Users & roles*; the
user receives an email link, logs in, and sets a password under *Settings*.

## Running locally

Requires Elixir 1.19 / OTP 28 and PostgreSQL (`postgres`/`postgres` on localhost by default).

```bash
mix setup          # deps, database, migrations, seeds
mix phx.server     # http://localhost:4000
```

The seeds create KNRA staff for every role, four RPM lanes, fee schedule v1 and six sample
applications driven through the real workflow. The shared development password is at the
top of `priv/repo/seeds.exs`. Sent emails (login links, alerts) appear at `/dev/mailbox`.

```bash
mix ecto.reset     # drop, recreate and reseed
mix test
mix precommit      # compile with warnings as errors, format, test
```

## Container status API (for KenTrade)

`POST /api/kentrade/container-status` — up to 100 containers per call. Authentication mirrors
KenTrade's own API: `From: <STATUS_API_FROM>` and
`Authorization: Basic <sha256_hex("STATUS_API_USERNAME:STATUS_API_PASSWORD")>`.

```json
[
  {"containerNumber": "MSKU9930211"},
  {"containerNumber": "PONU3345671", "billOfLadingNumber": "PONUBL2026033456"}
]
```

Each response item echoes `containerNumber` and gives `status`: `CLEARED`, `DETAINED`,
`IN_PROGRESS` or `NOT_FOUND` (plus `INVALID_REQUEST` for a malformed item). Found items also carry
`stage`, `applicationReference`, `screenedAt`, `clearedAt`, `certificateNumber`,
`manifestNumber`, `billOfLadingNumbers`, `ucrNumbers` and `matchedBy`.

**Reused containers.** One container number can have many screenings, one per arrival. Each
screening stores the manifest, B/L and UCR numbers KenTrade returned at scan time.

- If the request item includes `manifestNumber`, `billOfLadingNumber` or `ucrNumber`, only the
  screening for that arrival is returned (`matchedBy: "ARRIVAL"`); if that arrival has not been
  screened the answer is `NOT_FOUND`, even when an earlier voyage was cleared.
- With only `containerNumber`, the latest screening is returned if it is within
  `STATUS_WINDOW_DAYS` (default 60) — `matchedBy: "CONTAINER"`. Older screenings are treated as a
  previous arrival (`NOT_FOUND`).
- If the only recent screening has no KenTrade identifiers (lookup failed at scan time) it is
  returned with `matchedBy: "CONTAINER_ONLY"`.

A new RPM pass is refused only while a *recent, open* screening exists for the container; detained
screenings and screenings older than the window do not block a new arrival.

Every inbound call is logged under *Integrations*.

## Configuration

KenTrade PGA Container Enquiry API (`config/runtime.exs`):

| Variable | Purpose |
|---|---|
| `KENTRADE_BASE_URL` | Trial or production base URL issued by KenTrade (the path `/TFBSEW/cusLogin/pga/container-enquiry` is appended) |
| `KENTRADE_USERNAME` / `KENTRADE_PASSWORD` | Sent as `Authorization: Basic <sha256_hex("username:password")>` |
| `KENTRADE_AGENCY_CODE` | Sent in the `From` header |
| `KENTRADE_MOCK` | `true` serves lookups from the built-in mock (the default in dev) |
| `STATUS_API_FROM` / `STATUS_API_USERNAME` / `STATUS_API_PASSWORD` | Credentials KenTrade uses to call our container status API |
| `STATUS_WINDOW_DAYS` | Container-only status queries ignore screenings older than this (default 60) |

Other settings:

| Variable / config | Purpose |
|---|---|
| `SIMULATORS_ENABLED` | Enables the RPM & M-Pesa simulator (on in dev, off otherwise) |
| `UPLOADS_DIR` | Where inspection photos are stored (default `./uploads`) |
| `:alarm_sla_minutes` | Alarms waiting longer are flagged in the queue (default 15) |

In dev the mock KenTrade knows the demo containers (e.g. `OOLU4471228`, `MSKU7741293`),
answers `TRLU9001234` as TRANSIT, any other valid number as NOT_FOUND and `ERRU0000000`
with a server error.

## Not yet built

- Real RPM vendor feed and M-Pesa Daraja C2B callback endpoint. Both simulators call the
  same functions (`Knra.Screening.ingest_occupancy/1`, `Knra.Billing.record_mpesa_confirmation/1`)
  the real adapters will use.
- SMS notifications and emails to importers (KenTrade does not return importer contacts).
- M12 reporting & analytics.
