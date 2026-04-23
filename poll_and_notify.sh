#!/usr/bin/env bash
# Poll SailPoint ISC for access-request-status changes and post each
# one to a Teams channel via the Power Automate incoming webhook.
#
# Usage:
#   ./poll_and_notify.sh [-v|--verbose] [WINDOW_HOURS]
#
#   -v, --verbose  print the raw SailPoint response and the generated
#                  Teams card payload on stderr, per run.
#   WINDOW_HOURS   how far back to look on the first run (default 4).
#                  Ignored once .poll_state exists — delete the state
#                  file to reset the cursor.
#
# Examples:
#   ./poll_and_notify.sh                           # 4h lookback
#   ./poll_and_notify.sh 24                        # 24h lookback
#   ./poll_and_notify.sh -v                        # verbose
#   ./run_poller.sh 60                             # loop every 60s
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

# --- Parse args (order-independent) ---
VERBOSE=0
WINDOW_HOURS=4
while (( $# )); do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)
      sed -n '1,30p' "$0"; exit 0 ;;
    *)            WINDOW_HOURS="$1"; shift ;;
  esac
done

log_verbose() { (( VERBOSE )) && printf "[verbose] %s\n" "$*" >&2 || true; }

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

if (( VERBOSE )); then
  echo "==== SailPoint /v2025/access-request-status response ====" >&2
  echo "$RESP" | jq . >&2 2>/dev/null || echo "$RESP" >&2
  echo "==== end response ====" >&2
fi

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
  REQID="$(jq -r '.accessRequestId // .id // "?"'                     <<<"$ITEM")"
  REQ_NAME="$(jq -r '.name // ""'                                     <<<"$ITEM")"
  CREATED="$(jq -r '.created // ""'                                   <<<"$ITEM")"
  REMOVE_DATE="$(jq -r '(.requestedItems[0].removeDate // "")'        <<<"$ITEM")"
  IDENTITY="$(jq -r '(.requestedFor.name // .requestedFor.id // .requestedFor[0].name // .requestedFor[0].id // "?")' <<<"$ITEM")"
  ITEMNAME="$(jq -r '(.requestedItems[0].name // .requestedItems[0].id // "?")' <<<"$ITEM")"
  ITEMTYPE="$(jq -r '(.requestedItems[0].type // "?")'                <<<"$ITEM")"
  COMMENT="$(jq -r '(.requestedItems[0].comment // "")'               <<<"$ITEM")"

  # Overall request lifecycle state (authoritative):
  #   EXECUTING -> still moving through phases
  #   COMPLETED -> finished (check phase results to see approved vs rejected)
  #   CANCELLED/TERMINATED -> stopped
  EXEC_STATE="$(jq -r '.executionStatus // .state // "?"'             <<<"$ITEM")"

  # Any item/phase ended with a rejection?
  HAS_REJECTED="$(jq -r '[.requestedItems[]?.accessRequestPhases[]?.result] | any(. == "REJECTED")' <<<"$ITEM")"

  # Name + state of the current (last) phase - tells us if we're in
  # approval or provisioning while EXECUTING.
  LAST_PHASE_NAME="$(jq -r  '(.requestedItems[0].accessRequestPhases[-1].name   // "")' <<<"$ITEM")"
  LAST_PHASE_STATE="$(jq -r '(.requestedItems[0].accessRequestPhases[-1].state  // "")' <<<"$ITEM")"
  LAST_PHASE_RESULT="$(jq -r '(.requestedItems[0].accessRequestPhases[-1].result // "")' <<<"$ITEM")"

  # --- Human-friendly mappings ----------------------------------------
  case "$REQTYPE" in
    GRANT_ACCESS)  ACTION_VERB="grant"   ;;
    REVOKE_ACCESS) ACTION_VERB="revoke"  ;;
    *)             ACTION_VERB="$REQTYPE" ;;
  esac

  # Decide emoji + label from the combination of EXEC_STATE + rejections
  # + current phase. Prefer "awaiting approval" / "provisioning" over
  # the generic "in progress" when EXECUTING.
  if   [[ "$EXEC_STATE" == "CANCELLED" || "$EXEC_STATE" == "TERMINATED" ]]; then
    EMOJI="⚫"; STYLE="attention"; STATE_LABEL="Cancelled"
  elif [[ "$HAS_REJECTED" == "true" ]]; then
    EMOJI="🔴"; STYLE="attention"; STATE_LABEL="Rejected"
  elif [[ "$EXEC_STATE" == "EXECUTING" ]]; then
    EMOJI="⏳"; STYLE="warning"
    case "$LAST_PHASE_NAME" in
      *APPROVAL*)     STATE_LABEL="Awaiting approval" ;;
      *PROVISION*)    STATE_LABEL="Provisioning"      ;;
      *)              STATE_LABEL="In progress"       ;;
    esac
  elif [[ "$EXEC_STATE" == "COMPLETED" ]]; then
    EMOJI="🟢"; STYLE="good";      STATE_LABEL="Approved and provisioned"
  else
    EMOJI="⚪"; STYLE="default";   STATE_LABEL="$EXEC_STATE"
  fi

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

  # Capitalize the action verb for the title (grant -> Grant).
  ACTION_TITLE="$(tr '[:lower:]' '[:upper:]' <<< "${ACTION_VERB:0:1}")${ACTION_VERB:1}"
  TITLE="${EMOJI} ${ACTION_TITLE} ${ITEMTYPE_LABEL} • ${STATE_LABEL}"
  HEADLINE="**${ITEMNAME}** → **${IDENTITY}**"

  # Build body lines as flat TextBlocks. The earlier Container +
  # FactSet variant was rejected by Teams ("cards.unsupported") - this
  # shape is the one the initial working test used.
  BODY_ITEMS="$(jq -nc \
    --arg title    "$TITLE"    \
    --arg headline "$HEADLINE" \
    --arg reqtype  "${REQTYPE}"                                    \
    --arg state    "${STATE_LABEL}"                                \
    --arg item     "${ITEMNAME} (${ITEMTYPE_LABEL})"               \
    --arg req      "${NICE_CREATED:-$NICE_MOD}"                    \
    --arg until    "${NICE_REMOVE}"                                \
    --arg id       "${SHORT_REQID}"                                \
    --arg reqname  "${REQ_NAME}"                                   \
    --arg comment  "${COMMENT}"                                    '
    [ { type: "TextBlock", size: "Large",  weight: "Bolder", text: $title,    wrap: true }
    , { type: "TextBlock", size: "Medium", text: $headline, wrap: true }
    , { type: "TextBlock", text: ("**Type:** "        + $reqtype), wrap: true }
    , { type: "TextBlock", text: ("**State:** "       + $state),   wrap: true }
    , { type: "TextBlock", text: ("**Access item:** " + $item),    wrap: true }
    ]
    + (if $reqname != "" then [ { type: "TextBlock", text: ("**Request:** "    + $reqname), wrap: true } ] else [] end)
    + (if $req     != "" then [ { type: "TextBlock", text: ("**Requested:** "  + $req),     wrap: true } ] else [] end)
    + (if $until   != "" then [ { type: "TextBlock", text: ("**Valid until:** "+ $until),   wrap: true } ] else [] end)
    +                     [ { type: "TextBlock", text: ("**Request ID:** " + $id),   wrap: true, isSubtle: true } ]
    + (if $comment != "" then [ { type: "TextBlock", text: ("_Justification:_ " + $comment), wrap: true, isSubtle: true } ] else [] end)
  ')"

  CARD="$(jq -nc \
    --argjson body "$BODY_ITEMS" '{
      type: "message",
      attachments: [{
        contentType: "application/vnd.microsoft.card.adaptive",
        content: {
          "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
          type: "AdaptiveCard",
          version: "1.4",
          body: $body
        }
      }]
    }')"

  if (( VERBOSE )); then
    echo "---- event -------------------------------------------------" >&2
    echo "modified           : $MOD"               >&2
    echo "requestType        : $REQTYPE"           >&2
    echo "executionStatus    : $EXEC_STATE"        >&2
    echo "hasRejected        : $HAS_REJECTED"      >&2
    echo "lastPhase name     : $LAST_PHASE_NAME"   >&2
    echo "lastPhase state    : $LAST_PHASE_STATE"  >&2
    echo "lastPhase result   : $LAST_PHASE_RESULT" >&2
    echo "-> emoji           : $EMOJI"             >&2
    echo "-> stateLabel      : $STATE_LABEL"       >&2
    echo "identity           : $IDENTITY"          >&2
    echo "item               : $ITEMNAME ($ITEMTYPE)" >&2
    echo "reqId              : $REQID"             >&2
    echo "removeDate         : $REMOVE_DATE"       >&2
    echo "comment            : $COMMENT"           >&2
    echo "-- card --" >&2
    echo "$CARD" | jq . >&2 2>/dev/null || echo "$CARD" >&2
    echo "-- end event --" >&2
  fi

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
