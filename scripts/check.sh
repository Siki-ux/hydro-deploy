#!/usr/bin/env bash
# scripts/check.sh — Health check for the full hydro-platform stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$DEPLOY_DIR/.env"

[ -f "$ENV_FILE" ] && source <(grep -E '^[A-Z_]+=.+' "$ENV_FILE" | sed 's/\r//')
HOST="${PUBLIC_HOSTNAME:-localhost}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC}  $*"; }
fail() { echo -e "  ${RED}✗${NC}  $*"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "  ${YELLOW}~${NC}  $*"; }
FAILURES=0

# ─── HTTP check ───────────────────────────────────────────────────────────────

check_http() {
    local NAME="$1"
    local URL="$2"
    local EXPECTED_CODE="${3:-200}"

    local CODE
    CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "$URL" 2>/dev/null || echo "000")

    if [ "$CODE" = "$EXPECTED_CODE" ]; then
        pass "$NAME  ($URL → HTTP $CODE)"
    elif [ "$CODE" = "000" ]; then
        fail "$NAME  ($URL → no response / connection refused)"
    else
        warn "$NAME  ($URL → HTTP $CODE, expected $EXPECTED_CODE)"
    fi
}

# ─── Container check ──────────────────────────────────────────────────────────

check_containers() {
    echo -e "\n${BOLD}Container status${NC}"
    echo "────────────────────────────────────────────────────"

    # Get all containers in the hydro-platform project
    local CONTAINERS
    CONTAINERS=$(docker ps -a --filter "label=com.docker.compose.project=hydro-platform" \
        --format "{{.Names}}\t{{.Status}}" 2>/dev/null || echo "")

    if [ -z "$CONTAINERS" ]; then
        fail "No hydro-platform containers found. Run: make up"
        return
    fi

    local UNHEALTHY=0
    while IFS=$'\t' read -r NAME STATUS; do
        if echo "$STATUS" | grep -q "^Up"; then
            if echo "$STATUS" | grep -q "(healthy)"; then
                pass "$NAME  (healthy)"
            elif echo "$STATUS" | grep -q "(unhealthy)"; then
                fail "$NAME  (unhealthy) — check: docker logs $NAME"
                UNHEALTHY=$((UNHEALTHY+1))
            else
                pass "$NAME  (running)"
            fi
        elif echo "$STATUS" | grep -q "^Exited"; then
            EXITCODE=$(echo "$STATUS" | grep -oP '(?<=Exited \()\d+')
            if [ "${EXITCODE:-0}" = "0" ]; then
                warn "$NAME  (exited 0 — init/seed container, expected)"
            else
                fail "$NAME  (exited $EXITCODE) — check: docker logs $NAME"
            fi
        else
            warn "$NAME  ($STATUS)"
        fi
    done <<< "$CONTAINERS"
}

# ─── Endpoint checks ──────────────────────────────────────────────────────────

check_endpoints() {
    echo -e "\n${BOLD}Endpoint reachability${NC}"
    echo "────────────────────────────────────────────────────"

    # TSM nginx proxy
    check_http "TSM proxy"         "http://$HOST"                  "200"

    # FROST SensorThings
    check_http "FROST API"         "http://$HOST/sta/v1.1"         "200"

    # Keycloak
    check_http "Keycloak"          "http://$HOST:8081"             "200"

    # water-dp API
    check_http "water-dp API"      "http://$HOST/water-api/health" "200"
    check_http "API docs"          "http://$HOST/water-api/api/v1/docs" "200"

    # Frontend
    check_http "Frontend portal"   "http://$HOST/portal"           "200"

    # GeoServer
    check_http "GeoServer"         "http://$HOST:8079/geoserver/web/" "200"

    # MinIO console
    check_http "MinIO console"     "http://$HOST:9001"             "200"
}

# ─── Tunnel check ─────────────────────────────────────────────────────────────

check_tunnel() {
    echo -e "\n${BOLD}Cloudflare Tunnel${NC}"
    echo "────────────────────────────────────────────────────"

    if docker ps --filter "name=hydro-cloudflared" --filter "status=running" | grep -q cloudflared; then
        pass "cloudflared container is running"
        # Try to read tunnel status from cloudflared logs
        local LAST_LOG
        LAST_LOG=$(docker logs hydro-cloudflared --tail=5 2>&1 | grep -i "connected\|registered\|error" | tail -1 || echo "")
        [ -n "$LAST_LOG" ] && warn "Last log: $LAST_LOG"
    else
        warn "cloudflared is not running (start with: make up-tunnel)"
    fi
}

# ─── Sync variable check ──────────────────────────────────────────────────────

check_env_sync() {
    echo -e "\n${BOLD}Environment variable consistency${NC}"
    echo "────────────────────────────────────────────────────"

    [ -f "$ENV_FILE" ] || { fail ".env not found"; return; }

    # Check @sync pairs must be equal
    check_pair() {
        local KEY1="$1" KEY2="$2"
        local VAL1 VAL2
        VAL1=$(grep -E "^${KEY1}=" "$ENV_FILE" | cut -d= -f2-)
        VAL2=$(grep -E "^${KEY2}=" "$ENV_FILE" | cut -d= -f2-)
        if [ "$VAL1" = "$VAL2" ]; then
            pass "$KEY1 == $KEY2"
        else
            fail "$KEY1 and $KEY2 differ — they must be identical"
        fi
    }

    check_pair "DATABASE_PASSWORD"        "TIMEIO_DB_PASSWORD"
    check_pair "DATABASE_PASSWORD"        "MQTT_AUTH_POSTGRES_PASS"
    check_pair "THING_MANAGEMENT_MQTT_PASS" "MQTT_PASSWORD"
    check_pair "KEYCLOAK_ADMIN_PASS"      "KEYCLOAK_ADMIN_PASSWORD"
    check_pair "OBJECT_STORAGE_ROOT_PASSWORD" "MINIO_SECRET_KEY"

    # Warn about remaining changeme placeholders
    local REMAINING
    REMAINING=$(grep -c "changeme" "$ENV_FILE" 2>/dev/null || echo 0)
    if [ "$REMAINING" -gt 0 ]; then
        fail "$REMAINING variable(s) still set to 'changeme' — run: make secrets"
    else
        pass "No placeholder values remaining in .env"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Hydro Platform — Health Check${NC}"
echo "════════════════════════════════════════════════════"

check_containers
check_endpoints
check_tunnel
check_env_sync

echo ""
echo "════════════════════════════════════════════════════"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}All checks passed.${NC}"
else
    echo -e "${RED}$FAILURES check(s) failed.${NC} Review the output above."
    exit 1
fi
echo ""
