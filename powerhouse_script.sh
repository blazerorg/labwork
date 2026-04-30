#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG & ARGS ---
RENDER_API_KEY="${1:-}"
GITLAB_REPO_URL="${2:-}"
MAX_BUILDS="4"
DRY_RUN=false

shift 2 || : 
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) MAX_BUILDS="$1"; shift ;;
  esac
done

[[ -z "$RENDER_API_KEY" || -z "$GITLAB_REPO_URL" ]] && { echo "Usage: $0 <API_KEY> <URL> [MAX] [--dry-run]"; exit 1; }

SESSION_HASH=$(echo -n "$RENDER_API_KEY" | md5sum | cut -d' ' -f1)
STATE_FILE="$HOME/.powerhouse_${SESSION_HASH}.state"
FLEET_FILE="$HOME/.powerhouse_${SESSION_HASH}.fleet"
BASE_NAME="powerhouse-web-node"
POLL_INTERVAL=10 
TIMEOUT_MINUTES=45
SLEEP_SECONDS=$(( 16 * 3600 ))
API="https://api.render.com/v1"
AUTH_HDR="Authorization: Bearer ${RENDER_API_KEY}"
ACC_HDR="Accept: application/json"

die() { echo -e "\n\n✗ ERROR: $*" >&2; exit 1; }
rget() { curl -s -H "$AUTH_HDR" -H "$ACC_HDR" "${API}$1"; }

show_cooldown_dashboard() {
    local end_time=$1
    local current_deployment=$2
    while true; do
        local now=$(date +%s)
        local left=$(( end_time - now ))
        if (( left <= 0 )); then break; fi
        clear
        echo "============================================================"
        echo "💤 POWERHOUSE COOLDOWN: Account ${SESSION_HASH:0:8}"
        echo "============================================================"
        echo "Next Deployment:  $((current_deployment + 1)) of $MAX_BUILDS"
        printf "Remaining Sleep:  %02dh %02dm %02ds\n" $((left/3600)) $(( (left%3600)/60 )) $((left%60))
        echo "------------------------------------------------------------"
        echo "VERIFIED FLEET (Local Cache):"
        [[ -f "$FLEET_FILE" ]] && cat "$FLEET_FILE" || echo "No nodes deployed yet."
        echo "------------------------------------------------------------"
        echo "LIVE API STATUS:"
        local services
        services=$(rget "/services?limit=100")
        if [[ $(echo "$services" | jq 'type' 2>/dev/null) == "array" ]]; then
            echo "$services" | jq -r ".[] | select(.service.name | contains(\"$BASE_NAME\")) | \"• \" + .service.name + \" (Online)\""
        else
            echo "API Syncing..."
        fi
        echo "============================================================"
        sleep 60
    done
}

# --- MAIN ---
# --- NEW CODE (VPS-Driven/Dynamic) ---
completed_count=$(( ${3:-1} - 1 ))
last_success_ts=0

REGION_RESP=$(rget "/regions")
mapfile -t POOL < <(echo "$REGION_RESP" | jq -r '.[] | select(.name != "singapore") | .name' 2>/dev/null)
[[ ${#POOL[@]} -eq 0 ]] && POOL=("frankfurt" "oregon" "ohio" "virginia")
TOTAL_REGIONS=${#POOL[@]}

for (( i=$((completed_count + 1)); i<=MAX_BUILDS; i++ )); do
    
    if [[ "$last_success_ts" -gt 0 && "$DRY_RUN" = false ]]; then
        show_cooldown_dashboard $(( last_success_ts + SLEEP_SECONDS )) "$((i-1))"
    fi

    echo -e "\n🚀 DEPLOYMENT $i / $MAX_BUILDS"
    REGION=${POOL[$(( (i - 1) % TOTAL_REGIONS ))]}
    
    OWNER_RESP=$(rget "/owners?limit=1")
    OWNER_ID=$(echo "$OWNER_RESP" | jq -r '.[0].owner.id // .[0].team.id // empty')
    
    EXISTING_RESP=$(rget "/services?limit=100")
    LAST_IDX=$(echo "$EXISTING_RESP" | jq -r '.[].service.name' 2>/dev/null | grep -oP "${BASE_NAME}-\K[0-9]+" | sort -rn | head -n 1 || echo "0")
    SERVICE_NAME="${BASE_NAME}-$((LAST_IDX + (i - completed_count)))"

    if [ "$DRY_RUN" = true ]; then
        echo "🔍 [DRY RUN] Would create: $SERVICE_NAME in $REGION"
        continue
    fi

    # Create Service
    CREATE_RESP=$(curl -s -w "\n%{http_code}" -X POST "${API}/services" \
      -H "$AUTH_HDR" -H "Content-Type: application/json" -H "$ACC_HDR" \
      -d "{
        \"name\": \"${SERVICE_NAME}\",
        \"type\": \"web_service\",
        \"ownerId\": \"${OWNER_ID}\",
        \"repo\": \"${GITLAB_REPO_URL}\",
        \"autoDeploy\": \"yes\",
        \"serviceDetails\": {
          \"runtime\": \"docker\", \"plan\": \"pro_ultra\", \"region\": \"${REGION}\",
          \"envSpecificDetails\": { \"dockerCommand\": \"./run_entrypoint.sh\" }
        }
      }")

    HTTP_CODE=$(tail -1 <<< "$CREATE_RESP")
    [[ "$HTTP_CODE" =~ ^2 ]] || die "API Error ($HTTP_CODE)"
    SERVICE_ID=$(echo "$CREATE_RESP" | sed '$ d' | jq -r '.service.id // .id')

    # Monitor Build
    echo "→ Monitoring $SERVICE_NAME..."
    START_MONITOR=$(date +%s)
    while true; do
        NOW=$(date +%s); ELAPSED=$(( NOW - START_MONITOR ))
        (( ELAPSED > TIMEOUT_MINUTES * 60 )) && die "Timeout."
        
        STATUS=$(rget "/services/${SERVICE_ID}/deploys?limit=1" | jq -r '.[0].deploy.status // "pending"')
        printf "\r  [%02dm %02ds] Status: %s             " "$((ELAPSED/60))" "$((ELAPSED%60))" "$STATUS"
        
        if [[ "$STATUS" == "live" ]]; then
            SSH_STR="ssh ${SERVICE_ID}@ssh.${REGION}.render.com"
            echo -e "\n✓ NODE READY: $SSH_STR"
            echo "• $SERVICE_NAME: $SSH_STR" >> "$FLEET_FILE"
            break
        fi
        [[ "$STATUS" == "build_failed" ]] && die "Build failed."
        sleep "$POLL_INTERVAL"
    done

    last_success_ts=$(date +%s)
    echo "completed_count=$i; last_success_ts=$last_success_ts" > "$STATE_FILE"
done

[[ "$DRY_RUN" = false ]] && rm -f "$STATE_FILE" "$FLEET_FILE"
echo "✅ Session complete."
