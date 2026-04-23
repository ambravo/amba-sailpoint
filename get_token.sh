#!/usr/bin/env bash
# Fetch SailPoint OAuth token via client_credentials.
# Usage: source .env && ./get_token.sh > token.txt
set -euo pipefail
: "${SAILPOINT_TENANT_API:?}" "${SAILPOINT_CLIENT_ID:?}" "${SAILPOINT_CLIENT_SECRET:?}"

curl -sS -X POST "${SAILPOINT_TENANT_API}/oauth/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${SAILPOINT_CLIENT_ID}" \
  --data-urlencode "client_secret=${SAILPOINT_CLIENT_SECRET}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])"
