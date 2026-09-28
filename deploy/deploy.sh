#!/usr/bin/env bash
# Deploys the current branch of the checked-out repo as a new release.
#
# Run this ON THE SERVER (as root, like the systemd unit) from inside the
# source checkout (/srv/knra/repo). It builds the release in place (so it always matches the
# server's own Erlang/Elixir/OS, no cross-compilation), runs migrations, then
# atomically swaps /srv/knra/current to the new release and restarts the service.
#
# One-time server setup is in ../DEPLOYMENT.md — this script assumes the
# directory layout, env file and systemd unit described there already exist.
set -euo pipefail

APP=knra
BASE_DIR=/srv/knra
RELEASES_DIR="$BASE_DIR/releases"
CURRENT_LINK="$BASE_DIR/current"
ENV_FILE=/etc/knra/knra.env
KEEP_RELEASES=5

cd "$(dirname "$0")/.."

# if [ "$(id -un)" != "knra" ]; then
#   echo "Run this as the knra user (sudo -u knra $0)" >&2
#   exit 1
# fi

# PORT, DATABASE_URL etc. live in the env file, not this shell — migrations and
# the health check below need them.
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# `current` must be a symlink. If it is a real directory (e.g. created by hand),
# `ln -sfn` below would put the link *inside* it and systemd would keep failing
# with 203/EXEC.
if [ -e "$CURRENT_LINK" ] && [ ! -L "$CURRENT_LINK" ]; then
  echo "$CURRENT_LINK exists but is not a symlink — remove it (rm -rf $CURRENT_LINK) and re-run." >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> Fetching latest $BRANCH"
git fetch --quiet origin
git reset --hard "origin/$BRANCH"

export MIX_ENV=prod

echo "==> Installing dependencies"
mix deps.get --only prod

echo "==> Compiling and building assets"
mix compile
mix assets.deploy

echo "==> Building release"
mix release --overwrite

RELEASE_ID="$(date +%Y%m%d%H%M%S)"
RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"
echo "==> Unpacking release to $RELEASE_DIR"
mkdir -p "$RELEASE_DIR"
tar -xzf "_build/prod/$APP-"*.tar.gz -C "$RELEASE_DIR"

echo "==> Running migrations"
"$RELEASE_DIR/bin/migrate"

PREVIOUS_RELEASE="$(readlink "$CURRENT_LINK" || true)"

echo "==> Switching current -> $RELEASE_ID"
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"

echo "==> Restarting service"
sudo systemctl restart "$APP"

echo "==> Waiting for the app to come up"
for i in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${PORT:-4000}/health"; then
    echo "==> Deploy OK ($RELEASE_ID)"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "App did not respond after restart — check: journalctl -u $APP -n 100" >&2
    if [ -n "$PREVIOUS_RELEASE" ]; then
      echo "To roll back: ln -sfn $PREVIOUS_RELEASE $CURRENT_LINK && sudo systemctl restart $APP" >&2
      echo "(migrations are not rolled back automatically)" >&2
    fi
    exit 1
  fi
  sleep 1
done

echo "==> Pruning old releases (keeping last $KEEP_RELEASES)"
ls -1t "$RELEASES_DIR" | tail -n "+$((KEEP_RELEASES + 1))" | while read -r old; do
  rm -rf "${RELEASES_DIR:?}/$old"
done
