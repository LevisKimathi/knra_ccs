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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
