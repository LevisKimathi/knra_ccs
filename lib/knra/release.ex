defmodule Knra.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :knra

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  ## First-deploy bootstrap. Run against the running release, e.g.
  ##
  ##     /srv/knra/current/bin/knra rpc 'Knra.Release.create_super_admin("admin@knra.go.ke", "System Admin")'
  ##     /srv/knra/current/bin/knra rpc 'Knra.Release.create_super_admin("admin@knra.go.ke", "System Admin", password: "at-least-12-chars")'
  ##     /srv/knra/current/bin/knra rpc 'Knra.Release.create_supervisor("l.njoroge@knra.go.ke", "Dr. L. Njoroge")'
  ##     /srv/knra/current/bin/knra rpc 'Knra.Release.seed_fee_schedule()'
  ##     /srv/knra/current/bin/knra rpc 'Knra.Release.seed_lanes()'
  ##     /srv/knra/current/bin/knra rpc 'Knra.Release.create_api_client("Kenya Trade Network Agency", "KENTRADE", "kentrade")'
  ##     /srv/knra/current/bin/knra rpc 'Knra.Release.simulate_statuses("MRKU9937602 CLEARED, INBU5333934 DETAINED, MRKU2415627 IN_PROGRESS, MSKU2728942 NOT_FOUND")'
  ##
  ## Options: `station:` (default "KNRA HQ, Nairobi") and `password:`. With a
  ## password the account is created confirmed and ready for password login, and
  ## no email is sent (for servers without a mailer). Without one, a login link is
  ## printed and emailed.

  @doc "Creates a supervisor account (there is no self-registration)."
  def create_supervisor(email, name, opts \\ []) do
    create_admin(email, name, "supervisor", opts)
  end

  @doc """
  Creates a super admin (every permission, and the only role that can manage
  other super admins). Only possible from the server console or by another
  super admin.
  """
  def create_super_admin(email, name, opts \\ []) do
    create_admin(email, name, "super_admin", opts)
  end

  defp create_admin(email, name, role, opts) do
    alias Knra.Accounts.User

    password = opts[:password]
    station = opts[:station] || "KNRA HQ, Nairobi"

    changeset =
      %User{}
      |> User.admin_changeset(%{email: email, name: name, role: role, station: station})
      |> then(fn cs ->
        if password,
          do:
            cs
            |> User.password_changeset(%{password: password})
            |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second)),
          else: cs
      end)

    case Knra.Repo.insert(changeset) do
      {:ok, user} ->
        Knra.Audit.log(
          "System (bootstrap)",
          :user,
          user.email,
          "#{User.role_label(role)} account created from the server console",
          if(password, do: "Created with a password (no login email)")
        )

        if password do
          IO.puts(
            "Created #{user.email}. Log in at #{KnraWeb.Endpoint.url() <> KnraWeb.Endpoint.path("/users/log-in")} with the password you set."
          )
        else
          Knra.Accounts.deliver_login_instructions(user, fn token ->
            url = KnraWeb.Endpoint.url() <> KnraWeb.Endpoint.path("/users/log-in/" <> token)
            IO.puts("Login link (valid 15 minutes, also emailed): #{url}")
            url
          end)

          IO.puts("Created #{user.email}.")
        end

        {:ok, user.id}

      {:error, cs} ->
        errors =
          cs
          |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
            Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)
          |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &"#{field} #{&1}") end)

        IO.puts("Not created: #{Enum.join(errors, "; ")}")
        {:error, errors}
    end
  end

  @doc """
  Loads the gazetted fee schedule as version 1 if no approved schedule exists.
  Later changes go through Fee schedule (proposal + second-supervisor approval).
  """
  def seed_fee_schedule(effective_from \\ ~D[2026-07-01]) do
    import Ecto.Query
    alias Knra.Billing.{FeeItem, FeeSchedule}

    if Knra.Repo.exists?(from s in FeeSchedule, where: s.status == "approved") do
      IO.puts("An approved fee schedule already exists — nothing to do.")
      :exists
    else
      {:ok, _} =
        Knra.Repo.transaction(fn ->
          schedule =
            Knra.Repo.insert!(%FeeSchedule{
              version: 1,
              effective_from: effective_from,
              status: "approved",
              note: "Initial gazetted schedule (loaded at deployment)",
              approved_at: DateTime.utc_now(:second)
            })

          [
            {"screening", "Containerised cargo screening — per container (20ft/40ft)", "20.00",
             "2600.00"},
            {"rescreening", "Re-screening after failed occupancy (operator fault)", "0.00",
             "0.00"},
            {"secondary_inspection", "Secondary inspection at divert bay", "0.00", "0.00"},
            {"certified_copy", "Certified copy of screening certificate", "5.00", "650.00"}
          ]
          |> Enum.with_index()
          |> Enum.each(fn {{code, desc, usd, kes}, pos} ->
            Knra.Repo.insert!(%FeeItem{
              fee_schedule_id: schedule.id,
              code: code,
              description: desc,
              amount_usd: Decimal.new(usd),
              amount_kes: Decimal.new(kes),
              position: pos
            })
          end)

          Knra.Audit.log(
            "System (bootstrap)",
            :fee_schedule,
            "v1",
            "Fee schedule v1 loaded",
            "Effective #{Knra.Time.format_date(effective_from)}"
          )
        end)

      IO.puts(
        "Fee schedule v1 loaded (effective #{effective_from}). Review it under Fee schedule."
      )

      :ok
    end
  end

  @doc """
  Registers an organisation for the container status API and prints its
  credentials. Pass `password` to keep credentials already given to a partner;
  otherwise one is generated. Normally done under Administration → API clients.
  """
  def create_api_client(name, client_code, username, password \\ nil) do
    case Knra.ApiClients.create_client(
           "System (bootstrap)",
           %{"name" => name, "client_code" => client_code, "username" => username},
           password
         ) do
      {:ok, client, pw} ->
        IO.puts("API client #{client.name} registered.")
        IO.puts("  Client ID:          #{client.client_code}")
        IO.puts("  Username:           #{client.username}")
        if is_nil(password), do: IO.puts("  Password:           #{pw}  (not shown again)")
        {:ok, client.id}

      {:error, cs} ->
        IO.puts("Not registered: #{inspect(cs.errors)}")
        {:error, cs.errors}
    end
  end

  @doc """
  Stages containers at chosen screening statuses for partner API testing (see
  `Knra.Simulator.Batch` for the text format). Needs `SIMULATORS_ENABLED=true`.
  Runs as the super admin given by `as:` (email), or the first active one.
  Other options: `default:` (status for containers given without one; default
  spreads them over all statuses) and `lane:` (device code, default auto).
  """
  def simulate_statuses(text, opts \\ []) do
    import Ecto.Query
    alias Knra.Accounts.{Scope, User}
    alias Knra.Simulator.Batch

    user =
      case opts[:as] do
        nil ->
          Knra.Repo.one(
            from u in User,
              where: u.role == "super_admin" and u.status == "active",
              order_by: u.id,
              limit: 1
          )

        email ->
          Knra.Accounts.get_user_by_email(email)
      end

    case Batch.run(Scope.for_user(user), text, Keyword.take(opts, [:default, :lane])) do
      {:ok, results} ->
        IO.puts(
          String.pad_trailing("CONTAINER", 13) <>
            String.pad_trailing("TARGET", 44) <> String.pad_trailing("API ANSWER", 34) <> "RESULT"
        )

        IO.puts(Batch.format(results))
        failed = Enum.count(results, &match?({:error, _}, &1.result))
        IO.puts("\n#{length(results) - failed} staged, #{failed} failed (as #{user.email}).")
        {:ok, length(results) - failed, failed}

      {:error, reason} ->
        IO.puts("Nothing staged: #{Batch.error_message(reason)}")
        {:error, reason}
    end
  end

  @default_lanes [
    %{
      name: "Lane 1",
      device_code: "RPM-MSA-01",
      serial_number: "SN 8842-114",
      detector_type: "PVT gamma + He-3",
      terminal: "KOT",
      calibration_due_on: ~D[2026-12-12]
    },
    %{
      name: "Lane 2",
      device_code: "RPM-MSA-02",
      serial_number: "SN 8842-115",
      detector_type: "PVT gamma + He-3",
      terminal: "KOT",
      calibration_due_on: ~D[2026-12-12]
    },
    %{
      name: "Lane 3",
      device_code: "RPM-MSA-03",
      serial_number: "SN 8842-116",
      detector_type: "PVT gamma + He-3",
      terminal: "KOT",
      calibration_due_on: ~D[2026-10-20]
    },
    %{
      name: "Lane 4",
      device_code: "RPM-MSA-04",
      serial_number: "SN 8842-117",
      detector_type: "NaI spectroscopic",
      terminal: "KOT",
      calibration_due_on: ~D[2027-02-02]
    }
  ]

  @doc """
  Registers the Port of Mombasa RPM lanes (from the reviewed demo), all in
  service. Lanes whose device code or name already exists are skipped, so it is
  safe to run again. Correct serials and calibration dates under RPM devices.
  Pass your own list of maps (same keys) to register different devices.
  """
  def seed_lanes(lanes \\ @default_lanes) do
    alias Knra.Devices.Lane
    import Ecto.Query

    results =
      for attrs <- lanes do
        exists? =
          Knra.Repo.exists?(
            from l in Lane, where: l.device_code == ^attrs.device_code or l.name == ^attrs.name
          )

        if exists? do
          IO.puts("skipped  #{attrs.name} (#{attrs.device_code}) — already registered")
          :skipped
        else
          case %Lane{} |> Lane.changeset(attrs) |> Knra.Repo.insert() do
            {:ok, lane} ->
              Knra.Audit.log(
                "System (bootstrap)",
                :device,
                lane.device_code,
                "Device registered on #{lane.name}",
                lane.serial_number
              )

              IO.puts("added    #{lane.name} (#{lane.device_code}, #{lane.detector_type})")
              :added

            {:error, cs} ->
              IO.puts("failed   #{attrs.name}: #{inspect(cs.errors)}")
              :failed
          end
        end
      end

    Enum.frequencies(results)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
