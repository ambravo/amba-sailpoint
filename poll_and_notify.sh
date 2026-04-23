#!/usr/bin/env bash
# Poll SailPoint ISC for access-request-status changes and post each
# one to a Teams channel via the Power Automate incoming webhook.
#
# Usage:
#   ./poll_and_notify.sh [-v|--verbose] [-n|--dry-run] [WINDOW_HOURS]
#
#   -v, --verbose  print the raw SailPoint response and the generated
#                  Teams card payload on stderr, per run.
#   -n, --dry-run  implies --verbose, skips the Teams HTTP POST,
#                  bypasses the (requestId|stateLabel) dedup set so
#                  every event shows, and does not persist .poll_state
#                  or .poll_posted. Use this to inspect what SailPoint
#                  is returning without side-effects.
#   WINDOW_HOURS   how far back to look on the first run (default 4).
#                  Ignored once .poll_state exists — delete the state
#                  file to reset the cursor.
#
# Examples:
#   ./poll_and_notify.sh                           # 4h lookback
#   ./poll_and_notify.sh 24                        # 24h lookback
#   ./poll_and_notify.sh -v                        # verbose, real post
#   ./poll_and_notify.sh --dry-run 24              # 24h lookback, no-post
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

# --- Parse args first so env-check logic below can see flags ---
VERBOSE=0
DRY_RUN=0
WINDOW_HOURS=4
while (( $# )); do
  case "$1" in
    -v|--verbose) VERBOSE=1; shift ;;
    -n|--dry-run) DRY_RUN=1; VERBOSE=1; shift ;;
    -h|--help)
      sed -n '1,35p' "$0"; exit 0 ;;
    *)            WINDOW_HOURS="$1"; shift ;;
  esac
done

log_verbose() { (( VERBOSE )) && printf "[verbose] %s\n" "$*" >&2 || true; }

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
# TEAMS_WEBHOOK required only when actually posting.
if (( ! DRY_RUN )); then
  : "${TEAMS_WEBHOOK:?TEAMS_WEBHOOK required (or pass --dry-run)}"
fi

STATE_FILE="${STATE_FILE:-$SCRIPT_DIR/.poll_state}"
POSTED_FILE="${POSTED_FILE:-$SCRIPT_DIR/.poll_posted}"

# Dedup set of (requestId|stateLabel) keys. Backed by POSTED_FILE
# rather than an associative array so we work on macOS's stock
# bash 3.2 which doesn't support `declare -A`.
is_posted() {
  [[ -f "$POSTED_FILE" ]] && grep -Fqx "$1" "$POSTED_FILE" 2>/dev/null
}

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
POSTED_COUNT=0

while IFS= read -r ITEM; do
  MOD="$(jq -r '.modified // ""'     <<<"$ITEM")"
  [[ -z "$MOD" ]] && continue
  [[ ! "$MOD" > "$LAST" ]] && continue

  # Per-event reqId+stateLabel key used for dedup; computed again
  # below after we know STATE_LABEL. The pre-STATE_LABEL copy just
  # guards the cheap timestamp check above.

  # The /v2025/access-request-status endpoint returns ONE row per
  # item per request (flat, not nested). Paths are top-level.
  REQTYPE="$(jq -r '.requestType // "?"'                                  <<<"$ITEM")"
  REQID="$(jq -r   '.accessRequestId // "?"'                              <<<"$ITEM")"
  ITEMNAME="$(jq -r '.name // "?"'                                        <<<"$ITEM")"
  ITEMTYPE="$(jq -r '.type // "?"'                                        <<<"$ITEM")"
  ITEMID="$(jq -r   '.id // "?"'                                          <<<"$ITEM")"
  CREATED="$(jq -r  '.created // ""'                                      <<<"$ITEM")"
  REMOVE_DATE="$(jq -r '.removeDate // ""'                                <<<"$ITEM")"
  IDENTITY="$(jq -r '(.requestedFor.name // .requestedFor.id // "?")'     <<<"$ITEM")"
  REQUESTER="$(jq -r '(.requester.name // .requester.id // "")'           <<<"$ITEM")"
  COMMENT="$(jq -r  '.requesterComment.comment // ""'                     <<<"$ITEM")"

  # Top-level .state is authoritative.
  # Observed values: REQUEST_COMPLETED, REJECTED, CANCELLED, ERROR.
  # Others likely seen in live flows: EXECUTING, APPROVED, TERMINATED.
  EXEC_STATE="$(jq -r '.state // "?"'                                     <<<"$ITEM")"

  # Phases at the top level.
  LAST_PHASE_NAME="$(jq -r  '.accessRequestPhases[-1].name   // ""'       <<<"$ITEM")"
  LAST_PHASE_STATE="$(jq -r '.accessRequestPhases[-1].state  // ""'       <<<"$ITEM")"
  LAST_PHASE_RESULT="$(jq -r '.accessRequestPhases[-1].result // ""'      <<<"$ITEM")"

  # Rejection detected if any approvalDetails.status is REJECTED.
  HAS_REJECTED_APPROVAL="$(jq -r '[.approvalDetails[]?.status] | any(. == "REJECTED")' <<<"$ITEM")"

  # SOD violation (Separation of Duties). Worth surfacing.
  SOD_POLICY="$(jq -r '(.sodViolationContext.violationCheckResult.violatedPolicies[0].name // "")' <<<"$ITEM")"

  # Cancellation reason (when state = CANCELLED).
  CANCEL_COMMENT="$(jq -r '.cancelledRequestDetails.comment // ""' <<<"$ITEM")"

  # Approver comment on a completed approval, if any.
  APPROVER_COMMENT="$(jq -r '
    [.approvalDetails[]? | select(.comment != null) | .comment] | .[0] // ""
  ' <<<"$ITEM")"

  # Aggregated errors.
  ERROR_MSGS="$(jq -r '[.errorMessages[]?[]?.text] | join(" | ") // ""' <<<"$ITEM")"

  # --- Human-friendly mappings ----------------------------------------
  case "$REQTYPE" in
    GRANT_ACCESS)  ACTION_VERB="grant"   ;;
    REVOKE_ACCESS) ACTION_VERB="revoke"  ;;
    MODIFY_ACCESS) ACTION_VERB="modify"  ;;
    *)             ACTION_VERB="$REQTYPE" ;;
  esac

  case "$EXEC_STATE" in
    REQUEST_COMPLETED|APPROVED_AND_PROVISIONED|PROVISIONED|COMPLETED)
      EMOJI="🟢"; STYLE="good";      STATE_LABEL="Completed" ;;
    APPROVED)
      EMOJI="🟢"; STYLE="good";      STATE_LABEL="Approved" ;;
    REJECTED)
      EMOJI="🔴"; STYLE="attention"; STATE_LABEL="Rejected" ;;
    ERROR|FAILED)
      EMOJI="🔴"; STYLE="attention"; STATE_LABEL="Error" ;;
    CANCELLED|TERMINATED)
      EMOJI="⚫"; STYLE="attention"; STATE_LABEL="Cancelled" ;;
    EXECUTING)
      EMOJI="⏳"; STYLE="warning"
      case "$LAST_PHASE_NAME" in
        *APPROVAL*)  STATE_LABEL="Awaiting approval" ;;
        *PROVISION*) STATE_LABEL="Provisioning"      ;;
        *SOD*)       STATE_LABEL="Policy checks"     ;;
        *)           STATE_LABEL="In progress"       ;;
      esac
      ;;
    *)
      EMOJI="⚪"; STYLE="default";   STATE_LABEL="$EXEC_STATE" ;;
  esac

  # If the approval chain recorded a REJECTED step but top-level state
  # is ambiguous, upgrade label.
  if [[ "$HAS_REJECTED_APPROVAL" == "true" && "$STATE_LABEL" != "Rejected" && "$STATE_LABEL" != "Cancelled" ]]; then
    STATE_LABEL="Rejected by approver"
    EMOJI="🔴"; STYLE="attention"
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

  # Dedup: same (reqId + itemId + human state label) means we already
  # told Teams about this transition - skip. Item id is in the key so
  # two items from the same multi-item request each post separately.
  # Dry-run bypasses dedup.
  DEDUP_KEY="${REQID}|${ITEMID}|${STATE_LABEL}"
  if (( ! DRY_RUN )) && is_posted "$DEDUP_KEY"; then
    log_verbose "skip already-posted: $DEDUP_KEY"
    [[ "$MOD" > "$NEW_LAST" ]] && NEW_LAST="$MOD"
    continue
  fi

  # Build body lines as flat TextBlocks. The earlier Container +
  # FactSet variant was rejected by Teams ("cards.unsupported") - this
  # shape is the one the initial working test used.
  BODY_ITEMS="$(jq -nc \
    --arg title        "$TITLE"    \
    --arg headline     "$HEADLINE" \
    --arg reqtype      "${REQTYPE}"                            \
    --arg state        "${STATE_LABEL}"                        \
    --arg item         "${ITEMNAME} (${ITEMTYPE_LABEL})"       \
    --arg req          "${NICE_CREATED:-$NICE_MOD}"            \
    --arg until        "${NICE_REMOVE}"                        \
    --arg id           "${SHORT_REQID}"                        \
    --arg requester    "${REQUESTER}"                          \
    --arg comment      "${COMMENT}"                            \
    --arg cancel_cmt   "${CANCEL_COMMENT}"                     \
    --arg approver_cmt "${APPROVER_COMMENT}"                   \
    --arg sod          "${SOD_POLICY}"                         \
    --arg errs         "${ERROR_MSGS}"                         '
    [ { type: "TextBlock", size: "Large",  weight: "Bolder", text: $title,    wrap: true }
    , { type: "TextBlock", size: "Medium", text: $headline, wrap: true }
    , { type: "TextBlock", text: ("**Type:** "        + $reqtype), wrap: true }
    , { type: "TextBlock", text: ("**State:** "       + $state),   wrap: true }
    , { type: "TextBlock", text: ("**Access item:** " + $item),    wrap: true }
    ]
    + (if $requester != "" and $requester != "Ariel.Bravo" then [ { type: "TextBlock", text: ("**Requested by:** " + $requester), wrap: true } ] else [] end)
    + (if $req       != "" then [ { type: "TextBlock", text: ("**Requested:** "  + $req),   wrap: true } ] else [] end)
    + (if $until     != "" then [ { type: "TextBlock", text: ("**Valid until:** "+ $until), wrap: true } ] else [] end)
    +                       [ { type: "TextBlock", text: ("**Request ID:** " + $id), wrap: true, isSubtle: true } ]
    + (if $comment      != "" then [ { type: "TextBlock", text: ("_Justification:_ "      + $comment),      wrap: true, isSubtle: true } ] else [] end)
    + (if $approver_cmt != "" then [ { type: "TextBlock", text: ("_Approver comment:_ "   + $approver_cmt), wrap: true, isSubtle: true } ] else [] end)
    + (if $cancel_cmt   != "" then [ { type: "TextBlock", text: ("_Cancelled — reason:_ " + $cancel_cmt),   wrap: true, isSubtle: true } ] else [] end)
    + (if $sod          != "" then [ { type: "TextBlock", text: ("⚠️ _SoD policy:_ "       + $sod),          wrap: true, isSubtle: true } ] else [] end)
    + (if $errs         != "" then [ { type: "TextBlock", text: ("⚠️ _Error:_ "            + $errs),         wrap: true, isSubtle: true } ] else [] end)
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
    echo "modified            : $MOD"                     >&2
    echo "requestType         : $REQTYPE"                 >&2
    echo ".state              : $EXEC_STATE"              >&2
    echo "hasRejectedApproval : $HAS_REJECTED_APPROVAL"   >&2
    echo "lastPhase name      : $LAST_PHASE_NAME"         >&2
    echo "lastPhase state     : $LAST_PHASE_STATE"        >&2
    echo "lastPhase result    : $LAST_PHASE_RESULT"       >&2
    echo "-> emoji            : $EMOJI"                   >&2
    echo "-> stateLabel       : $STATE_LABEL"             >&2
    echo "identity            : $IDENTITY"                >&2
    echo "requester           : $REQUESTER"               >&2
    echo "item                : $ITEMNAME ($ITEMTYPE)"    >&2
    echo "itemId              : $ITEMID"                  >&2
    echo "reqId               : $REQID"                   >&2
    echo "removeDate          : $REMOVE_DATE"             >&2
    echo "comment             : $COMMENT"                 >&2
    echo "sodPolicy           : $SOD_POLICY"              >&2
    echo "cancelComment       : $CANCEL_COMMENT"          >&2
    echo "approverComment     : $APPROVER_COMMENT"        >&2
    echo "errorMsgs           : $ERROR_MSGS"              >&2
    echo "-- card --" >&2
    echo "$CARD" | jq . >&2 2>/dev/null || echo "$CARD" >&2
    echo "-- end event --" >&2
  fi

  if (( DRY_RUN )); then
    echo "DRY-RUN (not posted): ${REQTYPE} ${STATE_LABEL} ${IDENTITY} / ${ITEMNAME}  [${MOD}]"
  else
    curl -sS -X POST "$TEAMS_WEBHOOK" \
      -H "Content-Type: application/json" \
      -d "$CARD" > /dev/null
    echo "Posted: ${REQTYPE} ${STATE_LABEL} ${IDENTITY} / ${ITEMNAME}  [${MOD}]"

    # Record immediately so a crash mid-loop doesn't cause replays.
    echo "$DEDUP_KEY" >> "$POSTED_FILE"
  fi

  POSTED_COUNT=$((POSTED_COUNT + 1))
  [[ "$MOD" > "$NEW_LAST" ]] && NEW_LAST="$MOD"
done < <(echo "$RESP" | jq -c '.[]')

# ---------------------------------------------------------------------
# 4. Persist the latest timestamp seen (skipped in --dry-run).
# ---------------------------------------------------------------------
if (( ! DRY_RUN )) && [[ "$NEW_LAST" != "$LAST" ]]; then
  echo "$NEW_LAST" > "$STATE_FILE"
fi

if (( DRY_RUN )); then
  echo "DRY-RUN complete — seen=${POSTED_COUNT} (no Teams post, no state persisted) last_seen=${NEW_LAST}"
else
  echo "poll complete — posted=${POSTED_COUNT} last_seen=${NEW_LAST}"
fi
