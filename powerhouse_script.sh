#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
RENDER_API_KEY="${1:-}"
GITLAB_REPO_URL="${2:-}"
CURRENT_RUN_INDEX="${3:-1}" 

[[ -z "$RENDER_API_KEY" || -z "$GITLAB_REPO_URL" ]] && exit 1

API="https://api.render.com/v1"
AUTH_HDR="Authorization: Bearer ${RENDER_API_KEY}"
ACC_HDR="Accept: application/json"

# --- CONNECTIVITY & REGION ---
OWNER_ID=$(curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}/owners?limit=1" | jq -r '.[0].owner.id // .[0].team.id')
POOL=("frankfurt" "oregon" "ohio" "virginia")
REGION=${POOL[$(( (CURRENT_RUN_INDEX - 1) % 4 ))]}
SERVICE_NAME="powerhouse-web-${CURRENT_RUN_INDEX}"

# --- THE TICKLE (Strictly as requested) ---
CREATE_RESP=$(curl -s -X POST "${API}/services" \
  -H "$AUTH_HDR" -H "Content-Type: application/json" -H "$ACC_HDR" \
  -d "{
    \"name\": \"${SERVICE_NAME}\",
    \"type\": \"web_service\",
    \"ownerId\": \"${OWNER_ID}\",
    \"repo\": \"${GITLAB_REPO_URL}\",
    \"autoDeploy\": \"yes\",
    \"serviceDetails\": {
      \"runtime\": \"docker\",
      \"plan\": \"pro_ultra\",
      \"region\": \"${REGION}\",
      \"dockerCommand\": \"./run_entrypoint.sh\",
      \"disk\": {
        \"name\": \"power-disk-${CURRENT_RUN_INDEX}\",
        \"mountPath\": \"/var/data\",
        \"sizeGB\": 5
      }
    }
  }")

SERVICE_ID=$(echo "$CREATE_RESP" | jq -r '.service.id // .id')

# --- MONITORING LOOP ---
while true; do
    STATUS=$(curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}/services/${SERVICE_ID}/deploys?limit=1" | jq -r '.[0].deploy.status // "pending"')
    
    if [[ "$STATUS" == "live" ]]; then
        echo "RENDER_SSH_RESULT=ssh ${SERVICE_ID}@ssh.${REGION}.render.com"
        break
    fi
    
    if [[ "$STATUS" == "build_failed" ]]; then
        exit 1
    fi
    
    sleep 20
done
