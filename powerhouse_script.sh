#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG & ARGS ---
RENDER_API_KEY="${1:-}"
GITLAB_REPO_URL="${2:-}"
CURRENT_RUN_INDEX="${3:-1}" 
MAX_BUILDS="1" 
POLL_INTERVAL=10 
TIMEOUT_MINUTES=45
API="https://api.render.com/v1"
AUTH_HDR="Authorization: Bearer ${RENDER_API_KEY}"
ACC_HDR="Accept: application/json"

[[ -z "$RENDER_API_KEY" || -z "$GITLAB_REPO_URL" ]] && exit 1

die() { echo -e "✗ ERROR: $*" >&2; exit 1; }
rget() { curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}$1"; }

# --- STATELESS OFFSET ---
completed_count=$(( CURRENT_RUN_INDEX - 1 ))

REGION_RESP=$(rget "/regions")
mapfile -t POOL < <(echo "$REGION_RESP" | jq -r '.[] | select(.name != "singapore") | .name' 2>/dev/null)
[[ ${#POOL[@]} -eq 0 ]] && POOL=("frankfurt" "oregon" "ohio" "virginia")

REGION=${POOL[$(( completed_count % ${#POOL[@]} ))]}
SERVICE_NAME="powerhouse-web-${CURRENT_RUN_INDEX}"

# --- CREATE SERVICE ---
OWNER_ID=$(rget "/owners?limit=1" | jq -r '.[0].owner.id // .[0].team.id')

CREATE_RESP=$(curl -s -X POST "${API}/services" -H "$AUTH_HDR" -H "Content-Type: application/json" -H "$ACC_HDR" \
  -d "{\"name\": \"${SERVICE_NAME}\", \"type\": \"web_service\", \"ownerId\": \"${OWNER_ID}\", \"repo\": \"${GITLAB_REPO_URL}\", \"autoDeploy\": \"yes\", \"serviceDetails\": {\"runtime\": \"docker\", \"plan\": \"pro_ultra\", \"region\": \"${REGION}\"}}")

SERVICE_ID=$(echo "$CREATE_RESP" | jq -r '.service.id // .id')

# --- MONITOR ---
while true; do
    STATUS=$(rget "/services/${SERVICE_ID}/deploys?limit=1" | jq -r '.[0].deploy.status // "pending"')
    if [[ "$STATUS" == "live" ]]; then
        # This print is essential for the VPS to scrape
        echo "RENDER_SSH_RESULT=ssh ${SERVICE_ID}@ssh.${REGION}.render.com"
        break
    fi
    [[ "$STATUS" == "build_failed" ]] && die "Build failed."
    sleep "$POLL_INTERVAL"
done
