#!/usr/bin/env bash
# Simulates a rogue AI agent spamming SailPoint access-requests until rate-limited.
# Usage: source .env && ./rogue_bot.sh
set -euo pipefail
: "${SAILPOINT_TENANT_API:?}" "${SAILPOINT_IDENTITY_ID:?}" "${SAILPOINT_ACCESS_PROFILE_ID:?}"

TOKEN="$(./get_token.sh)"
ENDPOINT="${SAILPOINT_TENANT_API}/v3/access-requests"
N="${N:-300}"
CONCURRENCY="${CONCURRENCY:-25}"

# Build payload from template
PAYLOAD=$(sed \
  -e "s|__IDENTITY_ID__|${SAILPOINT_IDENTITY_ID}|g" \
  -e "s|__ACCESS_PROFILE_ID__|${SAILPOINT_ACCESS_PROFILE_ID}|g" \
  payload.json)

echo "Rogue agent firing ${N} requests (concurrency ${CONCURRENCY}) at ${ENDPOINT}"
echo "Watch for 429s..."
echo "----"

fire() {
  local i=$1
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "${ENDPOINT}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")
  printf "req=%03d  status=%s\n" "$i" "$code"
}
export -f fire
export TOKEN ENDPOINT PAYLOAD

seq 1 "$N" | xargs -n1 -P"${CONCURRENCY}" -I{} bash -c 'fire "$@"' _ {} \
  | tee bot_run.log

echo "----"
echo "Status code tally:"
awk '{print $3}' bot_run.log | sort | uniq -c | sort -rn
