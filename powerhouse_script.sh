#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
RENDER_API_KEY="${1:-}"
GITLAB_REPO_URL="${2:-}"
CURRENT_RUN_INDEX="${3:-1}" 

# Critical Validation
[[ -z "$RENDER_API_KEY" ]] && { echo "FATAL: RENDER_API_KEY is empty!"; exit 1; }
[[ -z "$GITLAB_REPO_URL" ]] && { echo "FATAL: GITLAB_REPO_URL is empty!"; exit 1; }

API="https://api.render.com/v1"
AUTH_HDR="Authorization: Bearer ${RENDER_API_KEY}"
ACC_HDR="Accept: application/json"

# --- CONNECTIVITY TEST ---
# Fetches the Owner ID required for the service creation payload
OWNER_ID=$(curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}/owners?limit=1" | jq -r '.[0].owner.id // .[0].team.id')

# --- STATELESS REGION ROTATION ---
# Rotates regions based on the run number sent by the VPS
POOL=("frankfurt" "oregon" "ohio" "virginia")
REGION=${POOL[$(( (CURRENT_RUN_INDEX - 1) % 4 ))]}
SERVICE_NAME="powerhouse-web-${CURRENT_RUN_INDEX}"

echo "Stateless Sync: Run #$CURRENT_RUN_INDEX targeting $REGION"

# --- THE RENDER TICKLE ---
# This POST request is what triggers activity on your Render dashboard
CREATE_RESP=$(curl -s -X POST "${API}/services" \
  -H "$AUTH_HDR" -H "Content-Type: application/json" -H "$ACC_HDR" \
  -d "{\"name\": \"${SERVICE_NAME}\", \"type\": \"web_service\", \"ownerId\": \"${OWNER_ID}\", \"repo\": \"${GITLAB_REPO_URL}\", \"autoDeploy\": \"yes\", \"serviceDetails\": {\"runtime\": \"docker\", \"plan\": \"pro_ultra\", \"region\": \"${REGION}\"}}")

SERVICE_ID=$(echo "$CREATE_RESP" | jq -r '.service.id // .id')

# --- MONITORING LOOP ---
# Stays active until Render is live, keeping the GitHub Action running for the VPS to scrape
while true; do
    STATUS=$(curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}/services/${SERVICE_ID}/deploys?limit=1" | jq -r '.[0].deploy.status // "pending"')
    
    if [[ "$STATUS" == "live" ]]; then
        # This specific string is what the VPS 'grep' is looking for
        echo "RENDER_SSH_RESULT=ssh ${SERVICE_ID}@ssh.${REGION}.render.com"
        break
    fi
    
    if [[ "$STATUS" == "build_failed" ]]; then
        echo "ERROR: Render build failed."
        exit 1
    fi
    
    sleep 20
done
