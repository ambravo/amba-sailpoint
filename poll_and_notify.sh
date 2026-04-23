#!/usr/bin/env bash
# Poll SailPoint ISC for access-request-status changes and post each
# one to a Teams channel via the Power Automate incoming webhook.
#
# Usage:
#   ./poll_and_notify.sh                                    # one-shot
#   while true; do ./poll_and_notify.sh; sleep 60; done     # loop every minute
#
# Auto-loads .env (next to the script) if present, so no need to
# `source .env` first. Existing env vars take precedence.
#
# State file (.poll_state by default) keeps the ISO 8601 timestamp of
# the last status we posted, so re-runs only post new changes.
#
# Required env (from .env or shell):
#   SAILPOINT_TENANT_API
#   SAILPOINT_CLIENT_ID       (PAT id or regular OAuth client id)
#   SAILPOINT_CLIENT_SECRET   (PAT secret or client secret)
#   TEAMS_WEBHOOK             (Power Automate Workflows URL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${SAILPOINT_TENANT_API:?}"
: "${SAILPOINT_CLIENT_ID:?}"
: "${SAILPOINT_CLIENT_SECRET:?}"
: "${TEAMS_WEBHOOK:?}"

STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/.poll_state}"

# On first run, seed "last seen" to now - 1h so we don't spam history.
if [[ -f "$STATE_FILE" ]]; then
  LAST="$(cat "$STATE_FILE")"
else
  LAST="$(date -u -v-1H +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
          || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S.000Z)"
fi

# ---------------------------------------------------------------------
# 1. OAuth client_credentials -> bearer token
# ---------------------------------------------------------------------
TOKEN="$(curl -sS -X POST "${SAILPOINT_TENANT_API}/oauth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${SAILPOINT_CLIENT_ID}" \
    --data-urlencode "client_secret=${SAILPOINT_CLIENT_SECRET}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")"

# ---------------------------------------------------------------------
# 2. Fetch latest access-request-status entries (newest first)
# ---------------------------------------------------------------------
RESP="$(curl -sS -G "${SAILPOINT_TENANT_API}/v2025/access-request-status" \
    --data-urlencode "sorters=-modified" \
    --data-urlencode "limit=50" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/json")"

# Fail fast if SailPoint returned an error object instead of an array.
if ! echo "$RESP" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "Unexpected response:" >&2
  echo "$RESP" >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 3. For each entry newer than LAST, POST an Adaptive Card to Teams.
# ---------------------------------------------------------------------
NEW_LAST="$LAST"
POSTED=0

while IFS= read -r ITEM; do
  MOD="$(jq -r '.modified // ""'     <<<"$ITEM")"
  [[ -z "$MOD" ]] && continue
  [[ ! "$MOD" > "$LAST" ]] && continue

  REQTYPE="$(jq -r '.requestType // "?"'                              <<<"$ITEM")"
  STATE="$(jq -r '.accessRequestPhases[-1].state // .state // "?"'    <<<"$ITEM")"
  REQID="$(jq -r '.accessRequestId // .id // "?"'                     <<<"$ITEM")"
  IDENTITY="$(jq -r '(.requestedFor.name // .requestedFor.id // "?")' <<<"$ITEM")"
  ITEMNAME="$(jq -r '(.requestedItems[0].name // .requestedItems[0].id // "?")' <<<"$ITEM")"
  ITEMTYPE="$(jq -r '(.requestedItems[0].type // "?")'                <<<"$ITEM")"

  TITLE="SailPoint • ${REQTYPE} • ${STATE}"
  SUBTITLE="${ITEMTYPE}: ${ITEMNAME}"
  BODY="Identity: ${IDENTITY}"
  META="Request: ${REQID} | ${MOD}"

  CARD="$(jq -n \
    --arg t "$TITLE"    \
    --arg s "$SUBTITLE" \
    --arg b "$BODY"     \
    --arg m "$META" '{
      type: "message",
      attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: [
            { type: "TextBlock", size: "Medium", weight: "Bolder", text: $t },
            { type: "TextBlock", text: $s, wrap: true },
            { type: "TextBlock", text: $b, wrap: true, isSubtle: true },
            { type: "TextBlock", text: $m, wrap: true, isSubtle: true, spacing: "Small" }
          ]
        }
      }]
    }')"

  curl -sS -X POST "$TEAMS_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$CARD" > /dev/null

  echo "Posted: ${REQTYPE} ${STATE} ${IDENTITY} / ${ITEMNAME}  [${MOD}]"
  POSTED=$((POSTED + 1))

  [[ "$MOD" > "$NEW_LAST" ]] && NEW_LAST="$MOD"
done < <(echo "$RESP" | jq -c '.[]')

# ---------------------------------------------------------------------
# 4. Persist the latest timestamp seen.
# ---------------------------------------------------------------------
if [[ "$NEW_LAST" != "$LAST" ]]; then
  echo "$NEW_LAST" > "$STATE_FILE"
fi

echo "poll complete — posted=${POSTED} last_seen=${NEW_LAST}"
