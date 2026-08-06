#!/usr/bin/env bash
# Deploys custom_components/homeconnect_ws to a running Home Assistant instance
# over SSH, then restarts HA so the new code is picked up.
#
# Usage: script/deploy.sh
# Config: copy .env.deploy.example to .env.deploy and fill in your values.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env.deploy"
COMPONENT="homeconnect_ws"
LOCAL_COMPONENTS_DIR="$REPO_ROOT/custom_components"
REMOTE_COMPONENTS_DIR="/config/custom_components"
REMOTE_DIR="$REMOTE_COMPONENTS_DIR/$COMPONENT"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found." >&2
  echo "       copy .env.deploy.example to .env.deploy and fill in your values." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a
source "$ENV_FILE"
set +a

: "${HA_SSH_HOST:?HA_SSH_HOST not set in .env.deploy}"
: "${HA_URL:?HA_URL not set in .env.deploy}"
: "${HA_TOKEN:?HA_TOKEN not set in .env.deploy}"

echo "==> Syncing $COMPONENT to $HA_SSH_HOST:$REMOTE_DIR"
# Full replace (via tar over ssh) rather than rsync: no rsync binary needed locally,
# and it cleanly handles files that were deleted locally since the last deploy.
tar czf - -C "$LOCAL_COMPONENTS_DIR" "$COMPONENT" | ssh "$HA_SSH_HOST" "
  set -e
  sudo rm -rf '$REMOTE_DIR'
  sudo tar xzf - -C '$REMOTE_COMPONENTS_DIR'
  sudo chown -R root:root '$REMOTE_DIR'
"

echo "==> Triggering Home Assistant restart ($HA_URL)"
# NOTE: HA's own web server frequently can't cleanly finish responding to this call,
# since it's tearing itself down mid-request. That shows up as an empty reply, a
# timeout, or a generic "500: Server got itself in trouble" page - none of which mean
# the restart failed. So we don't treat this response as authoritative; we fire it
# best-effort and instead confirm success by polling until HA answers again below.
curl -s -o /dev/null --max-time 5 \
  -X POST "$HA_URL/api/services/homeassistant/restart" \
  -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' || true

echo "==> Waiting for Home Assistant to come back up..."
deadline=$((SECONDS + 90))
up=0
while (( SECONDS < deadline )); do
  sleep 3
  if curl -sf -o /dev/null --max-time 3 "$HA_URL/"; then
    up=1
    break
  fi
done

if (( up == 1 )); then
  echo "==> Home Assistant is back up. Deploy complete."
else
  echo "warning: Home Assistant did not respond within 90s after restart." >&2
  echo "         The file sync succeeded regardless - check HA manually." >&2
  exit 1
fi
