# Deploying KNRA CCS

Releases are built **on the server** from a git checkout and swapped in atomically by
[`deploy/deploy.sh`](deploy/deploy.sh).
(root-run systemd service, env file under `/etc`). The steps below are done once per server.

## Layout

```
/srv/knra/
  repo/                 git checkout (build happens here)
  releases/<timestamp>/ unpacked releases (last 5 kept)
  current -> releases/<timestamp>
  uploads/              field-inspection photos (persist across releases)
/etc/knra/knra.env      configuration and secrets
/etc/systemd/system/knra.service
```

## One-time setup (Ubuntu)

1. **Toolchain**: Erlang/OTP 28 and Elixir 1.19, `git`, `curl`, `build-essential` (bcrypt is a
   NIF) and PostgreSQL 16. No Node.js is needed — esbuild and Tailwind binaries are downloaded by
   `mix assets.deploy`.

2. **Directories and checkout**
   ```bash
   mkdir -p /srv/knra/{releases,uploads}
   git clone <repo-url> /srv/knra/repo
   ```

3. **Database**
   ```bash
   sudo -u postgres createuser --pwprompt knra_web
   sudo -u postgres createdb -O knra_web knra_prod
   ```

4. **Configuration**
   ```bash
   mkdir -p /etc/knra
   cp /srv/knra/repo/deploy/knra.env.example /etc/knra/knra.env
   chmod 600 /etc/knra/knra.env
   ```
   Fill in `DATABASE_URL`, `SECRET_KEY_BASE` (`mix phx.gen.secret`), `PHX_HOST`, the KenTrade
   credentials and the container-status API credentials you give KenTrade. Pick a `PORT` no other
   app on the server uses. Until `SMTP_HOST` is set, emails — including
   staff login links — are written to `journalctl -u knra` instead of being sent.

5. **Service**
   ```bash
   cp /srv/knra/repo/deploy/knra.service /etc/systemd/system/
   systemctl daemon-reload
   systemctl enable knra
   ```
   The unit runs with `ProtectSystem=strict`; the only writable path is `/srv/knra/uploads`
   (`ReadWritePaths`). If `UPLOADS_DIRECTORY` is changed, change `ReadWritePaths` to match.

6. **Reverse proxy / TLS**: terminate HTTPS in nginx for `PHX_HOST` and proxy to
   `127.0.0.1:$PORT`, forwarding `X-Forwarded-Proto` and WebSocket upgrades (`/live`). The app
   redirects plain HTTP to HTTPS except for `/health` and localhost.

7. **API clients**: register each organisation that will query container status under
   *Administration → API clients* and send it `https://$PHX_HOST$PHX_PATH/api/container-status`
   with its credentials. Give KenTrade the server's public IP in case they allow-list callers.

## Deploying

```bash
/srv/knra/repo/deploy/deploy.sh
```

Fetches the branch, builds the release, runs migrations, switches `current`, restarts the
service and waits for `/health`. On failure it prints the rollback command.

## After the first deploy

The production database starts empty (seeds are for development only):

```bash
# First super admin — prints a login link (valid 15 min) and emails it; add everyone else from Users & roles
/srv/knra/current/bin/knra rpc 'Knra.Release.create_super_admin("admin@knra.go.ke", "System Admin")'

# No mail server yet? Create it with a password instead (confirmed, no email; min 12 characters)
/srv/knra/current/bin/knra rpc 'Knra.Release.create_super_admin("admin@knra.go.ke", "System Admin", password: "change-me-after-login")'

# (or a supervisor directly)
/srv/knra/current/bin/knra rpc 'Knra.Release.create_supervisor("l.njoroge@knra.go.ke", "Dr. L. Njoroge")'

# Gazetted fee schedule v1 (invoices cannot be raised without an approved schedule)
/srv/knra/current/bin/knra rpc 'Knra.Release.seed_fee_schedule()'
```

Run these with `bin/knra` (not `bin/server`, which always starts a new node), with the env file
loaded first: `cd /srv/knra/current && set -a && . /etc/knra/knra.env && set +a`.

API clients are normally added under **Administration → API clients**. To register one from the
console, keeping a password already given to the partner (omit it to generate one):

```bash
/srv/knra/current/bin/knra rpc 'Knra.Release.create_api_client("Kenya Trade Network Agency", "KENTRADE", "KENTRADE", "existing-password")'
```

Then, as the supervisor: register the RPM lanes under **RPM devices**, add a second supervisor
(fee changes need a different approver), and add the operational staff.

## Operations

- Logs: `journalctl -u knra -f`
- Remote console: `/srv/knra/current/bin/knra remote` (with the env file loaded)
- Roll back: `ln -sfn /srv/knra/releases/<previous> /srv/knra/current && systemctl restart knra`
  (database migrations are not reverted)
- Back up the database **and** `/srv/knra/uploads` together.
