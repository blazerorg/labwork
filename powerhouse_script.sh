#!/usr/bin/env bash
set -euo pipefail

echo "--- DEBUG START ---"
RENDER_API_KEY="${1:-}"
GITLAB_REPO_URL="${2:-}"
CURRENT_RUN_INDEX="${3:-1}"

# Verify Secrets aren't empty
if [[ -z "$RENDER_API_KEY" ]]; then echo "FATAL: RENDER_API_KEY is empty!"; exit 1; fi
if [[ -z "$GITLAB_REPO_URL" ]]; then echo "FATAL: GITLAB_REPO_URL is empty!"; exit 1; fi

echo "Targeting Run Index: $CURRENT_RUN_INDEX"
API="https://api.render.com/v1"
AUTH_HDR="Authorization: Bearer ${RENDER_API_KEY}"
ACC_HDR="Accept: application/json"

# Test API Connectivity
echo "Testing Render API connectivity..."
OWNER_ID=$(curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}/owners?limit=1" | jq -r '.[0].owner.id // .[0].team.id')
echo "Detected Owner ID: $OWNER_ID"

# Region Logic
POOL=("frankfurt" "oregon" "ohio" "virginia")
REGION=${POOL[$(( (CURRENT_RUN_INDEX - 1) % 4 ))]}
SERVICE_NAME="powerhouse-web-${CURRENT_RUN_INDEX}"
echo "Deploying $SERVICE_NAME to $REGION..."

# THE ACTUAL TICKLE
echo "Sending POST request to Render..."
CREATE_RESP=$(curl -s -X POST "${API}/services" \
  -H "$AUTH_HDR" -H "Content-Type: application/json" -H "$ACC_HDR" \
  -d "{\"name\": \"${SERVICE_NAME}\", \"type\": \"web_service\", \"ownerId\": \"${OWNER_ID}\", \"repo\": \"${GITLAB_REPO_URL}\", \"autoDeploy\": \"yes\", \"serviceDetails\": {\"runtime\": \"docker\", \"plan\": \"pro_ultra\", \"region\": \"${REGION}\"}}")

SERVICE_ID=$(echo "$CREATE_RESP" | jq -r '.service.id // .id')
echo "Service Created! ID: $SERVICE_ID"

# Wait for Live status
while true; do
    STATUS=$(curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}/services/${SERVICE_ID}/deploys?limit=1" | jq -r '.[0].deploy.status // "pending"')
    echo "Current Status: $STATUS"
    if [[ "$STATUS" == "live" ]]; then
        echo "RENDER_SSH_RESULT=ssh ${SERVICE_ID}@ssh.${REGION}.render.com"
        break
    fi
    sleep 15
done
