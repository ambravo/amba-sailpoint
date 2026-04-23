#!/usr/bin/env bash
# Poll SailPoint ISC for access-request-status changes and post each
# one to a Teams channel via the Power Automate incoming webhook.
#
# Usage:
#   ./poll_and_notify.sh [WINDOW_HOURS]
#
#   WINDOW_HOURS   how far back to look on the first run (default 4).
#                  Ignored once .poll_state exists — delete the state
#                  file to reset the cursor.
#
# Examples:
#   ./poll_and_notify.sh                           # 4h lookback
#   ./poll_and_notify.sh 24                        # 24h lookback
#   while true; do ./poll_and_notify.sh; sleep 60; done
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
#   SAILPOINT_IDENTITY_ID     (the identity whose access-requests to watch;
#                              the /v2025/access-request-status endpoint
#                              is per-identity, not global. "me" also works
#                              if the PAT belongs to that identity.)
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
: "${SAILPOINT_IDENTITY_ID:?}"
: "${TEAMS_WEBHOOK:?}"

STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/.poll_state}"
WINDOW_HOURS="${1:-4}"

# On first run (no state file), seed "last seen" to now - WINDOW_HOURS.
if [[ -f "$STATE_FILE" ]]; then
  LAST="$(cat "$STATE_FILE")"
else
  LAST="$(date -u -v-${WINDOW_HOURS}H +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
          || date -u -d "${WINDOW_HOURS} hours ago" +%Y-%m-%dT%H:%M:%S.000Z)"
  echo "seeded lookback: ${WINDOW_HOURS}h -> ${LAST}"
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
    --data-urlencode "requested-for=${SAILPOINT_IDENTITY_ID}" \
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
  REQ_NAME="$(jq -r '.name // ""'                                     <<<"$ITEM")"
  CREATED="$(jq -r '.created // ""'                                   <<<"$ITEM")"
  REMOVE_DATE="$(jq -r '(.requestedItems[0].removeDate // "")'        <<<"$ITEM")"
  IDENTITY="$(jq -r '(.requestedFor.name // .requestedFor.id // .requestedFor[0].name // .requestedFor[0].id // "?")' <<<"$ITEM")"
  ITEMNAME="$(jq -r '(.requestedItems[0].name // .requestedItems[0].id // "?")' <<<"$ITEM")"
  ITEMTYPE="$(jq -r '(.requestedItems[0].type // "?")'                <<<"$ITEM")"
  COMMENT="$(jq -r '(.requestedItems[0].comment // "")'               <<<"$ITEM")"

  # --- Human-friendly mappings ----------------------------------------
  case "$REQTYPE" in
    GRANT_ACCESS)  ACTION_VERB="granted"   ;;
    REVOKE_ACCESS) ACTION_VERB="revoked"   ;;
    *)             ACTION_VERB="$REQTYPE"  ;;
  esac

  case "$STATE" in
    APPROVED|PROVISIONED|EXECUTING|COMPLETED|COMPLETED_SUCCESS|SUCCESS)
      EMOJI="🟢"; STYLE="good";     STATE_LABEL="Approved" ;;
    REJECTED|CANCELLED|DENIED|FAILED|COMPLETED_ERROR|ERROR)
      EMOJI="🔴"; STYLE="attention";STATE_LABEL="Rejected" ;;
    PENDING|WAITING|NOT_STARTED)
      EMOJI="⏳"; STYLE="warning";  STATE_LABEL="Pending"  ;;
    *)
      EMOJI="⚪"; STYLE="default";  STATE_LABEL="$STATE"   ;;
  esac

  case "$ITEMTYPE" in
    ACCESS_PROFILE) ITEMTYPE_LABEL="Access Profile" ;;
    ROLE)           ITEMTYPE_LABEL="Role"           ;;
    ENTITLEMENT)    ITEMTYPE_LABEL="Entitlement"    ;;
    *)              ITEMTYPE_LABEL="$ITEMTYPE"      ;;
  esac

  # ISO -> "2026-04-23 18:42 UTC"
  fmt_ts() {
    [[ -z "$1" ]] && { echo ""; return; }
    echo "$1" | awk -F'[T:.]' '{printf "%s %s:%s UTC", $1, $2, $3}'
  }
  NICE_MOD="$(fmt_ts "$MOD")"
  NICE_CREATED="$(fmt_ts "$CREATED")"
  NICE_REMOVE="$(fmt_ts "$REMOVE_DATE")"
  SHORT_REQID="${REQID:0:12}..."

  TITLE="${EMOJI} ${ITEMTYPE_LABEL} ${ACTION_VERB} — ${STATE_LABEL}"
  HEADLINE="**${ITEMNAME}** → ${IDENTITY}"

  # Build FactSet facts conditionally (skip empty).
  FACTS="$(jq -nc \
    --arg reqtype "${REQTYPE}"        \
    --arg state   "${STATE_LABEL}"    \
    --arg who     "${IDENTITY}"       \
    --arg what    "${ITEMNAME} (${ITEMTYPE_LABEL})" \
    --arg req     "${NICE_CREATED:-$NICE_MOD}"      \
    --arg until   "${NICE_REMOVE}"    \
    --arg id      "${SHORT_REQID}"    \
    --arg reqname "${REQ_NAME}"       '
    [
      { title: "Type",         value: $reqtype },
      { title: "State",        value: $state },
      { title: "Identity",     value: $who },
      { title: "Access Item",  value: $what }
    ]
    + (if $reqname != ""    then [ { title: "Request Name", value: $reqname } ] else [] end)
    + (if $req != ""        then [ { title: "Requested",    value: $req     } ] else [] end)
    + (if $until != ""      then [ { title: "Valid Until",  value: $until   } ] else [] end)
    + [ { title: "Request ID", value: $id } ]
  ')"

  CARD="$(jq -nc \
    --arg title    "$TITLE"    \
    --arg headline "$HEADLINE" \
    --arg style    "$STYLE"    \
    --arg comment  "$COMMENT"  \
    --argjson facts "$FACTS" '{
      type: "message",
      attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: ([
            {
              type: "Container",
              style: $style,
              items: [
                { type: "TextBlock", size: "Large",  weight: "Bolder", text: $title, wrap: true },
                { type: "TextBlock", size: "Medium", text: $headline, wrap: true }
              ]
            },
            { type: "FactSet", facts: $facts }
          ] + (if $comment != "" then [
            {
              type: "Container",
              spacing: "Medium",
              items: [
                { type: "TextBlock", text: "_Justification_", isSubtle: true, weight: "Bolder", size: "Small" },
                { type: "TextBlock", text: $comment, wrap: true }
              ]
            }
          ] else [] end))
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
