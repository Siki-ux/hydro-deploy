#!/usr/bin/env bash
# scripts/start-docker.sh
#
# Stage-aware startup for the Hydro Platform under Docker / Docker Desktop.
#
# Mirrors the Podman variant (start-podman.sh) but uses
# `docker compose up -d <service>` to start each stage, relying on Docker
# Compose's native depends_on/condition support for intra-stage ordering.
#
# Startup order:
#   Stage 1: TSM core  (database, init, mqtt-broker, object-storage, keycloak,
#            frost, visualization, flyway, workers, cron, proxy)
#   Stage 2: postgres-app  (GeoServer's dedicated DB)
#   Stage 3: water-dp-geoserver + geoserver-init (one-shot schema seeder)
#   Stage 4: redis + api
#   Stage 5: worker + frontend
#   Stage 6: cloudflared  (only with --tunnel)
#
# Usage:
#   ./scripts/start-docker.sh [--tunnel]
#
# Called by:
#   make up
#   make up-tunnel

set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$DEPLOY_DIR")"
TSM_DIR="${TSM_DIR:-$PARENT_DIR/tsm-orchestration}"
WATER_DIR="${WATER_DIR:-$PARENT_DIR/water-dp}"
ENV_FILE="${ENV_FILE:-$DEPLOY_DIR/.env}"

TUNNEL=0
if [ "${1:-}" = "--tunnel" ]; then
    TUNNEL=1
fi

# ─── Proxy bypass ─────────────────────────────────────────────────────────────
# Corporate proxies can intercept even localhost connections.
# Ensure localhost traffic bypasses the proxy.
export no_proxy="${no_proxy:+$no_proxy,}localhost,127.0.0.1"
export NO_PROXY="$no_proxy"

# ─── Colours ──────────────────────────────────────────────────────────────────

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${CYAN}[hydro]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}     $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}   $*"; }
die()   { echo -e "${RED}[error]${NC}  $*" >&2; exit 1; }

# ─── Compose command ──────────────────────────────────────────────────────────

_FILES="\
  -f $TSM_DIR/docker-compose.yml \
  -f $WATER_DIR/docker-compose.yml \
  -f $WATER_DIR/docker-compose.tsm.yml \
  -f $DEPLOY_DIR/docker-compose.yml"

COMPOSE="docker compose --project-name hydro-platform $_FILES --env-file $ENV_FILE"
if [ "$TUNNEL" = "1" ]; then
    COMPOSE_FULL="$COMPOSE -f $DEPLOY_DIR/docker-compose.tunnel.yml"
else
    COMPOSE_FULL="$COMPOSE"
fi

# ─── Health polling ───────────────────────────────────────────────────────────

# wait_healthy <container_name> [<timeout_seconds>]
wait_healthy() {
    local container="$1"
    local timeout="${2:-300}"
    local waited=0
    local status

    info "Waiting for $container to be healthy (up to ${timeout}s)..."
    while [ "$waited" -lt "$timeout" ]; do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")
        case "$status" in
            healthy)
                ok "$container is healthy"
                return 0
                ;;
            unhealthy)
                die "$container reported unhealthy — check logs: docker logs $container"
                ;;
        esac
        sleep 5
        waited=$((waited + 5))
    done
    die "Timed out waiting for $container to become healthy after ${timeout}s"
}

# ─── Network ─────────────────────────────────────────────────────────────────

docker network inspect hydro-platform-net >/dev/null 2>&1 \
    || docker network create hydro-platform-net

# ─── Stage 1: TSM core ───────────────────────────────────────────────────────

TSM_SERVICES=(
    database
    init
    mqtt-broker
    object-storage
    keycloak
    frost
    visualization
    flyway
    proxy
    cron-scheduler
    worker-sync-extapi
    worker-sync-extsftp
    worker-file-ingest
    worker-mqtt-ingest
    worker-run-qaqc
    worker-configdb-updater
    worker-monitor-mqtt
    worker-thing-setup
    worker-grafana-user-orgs
    mqtt-cat
    timeio-db-api
)

info "Stage 1/5: Starting TSM core services..."
$COMPOSE_FULL up -d --no-build "${TSM_SERVICES[@]}"
wait_healthy hydro-platform-database-1 120

# ─── Stage 2: postgres-app ────────────────────────────────────────────────────

info "Stage 2/5: Starting postgres-app (GeoServer dedicated DB)..."
$COMPOSE_FULL up -d --no-build postgres-app
wait_healthy water-dp-postgres 120

# ─── Stage 3: GeoServer + geoserver-init ──────────────────────────────────────

info "Stage 3/5: Starting GeoServer..."
$COMPOSE_FULL up -d --no-build water-dp-geoserver
wait_healthy water-dp-geoserver 300

info "Starting geoserver-init (schema seeder)..."
$COMPOSE_FULL up -d --no-build geoserver-init

# ─── Stage 4: redis + api ────────────────────────────────────────────────────

info "Stage 4/5: Starting redis + api..."
$COMPOSE_FULL up -d --no-build redis api
wait_healthy water-dp-api 120

# ─── Stage 5: worker + frontend ──────────────────────────────────────────────

info "Stage 5/5: Starting worker + frontend..."
$COMPOSE_FULL up -d --no-build worker frontend

# ─── Stage 6: cloudflared ─────────────────────────────────────────────────────

if [ "$TUNNEL" = "1" ]; then
    info "Starting cloudflared tunnel..."
    $COMPOSE_FULL up -d --no-build cloudflared
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

PUBLIC_HOST=$(grep "^PUBLIC_HOSTNAME" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "localhost")

echo ""
ok "Stack started (docker). Access points:"
echo "    Portal:    http://${PUBLIC_HOST}/portal"
echo "    API docs:  http://${PUBLIC_HOST}/water-api/api/v1/docs"
echo "    Keycloak:  http://${PUBLIC_HOST}:8081"
echo "    GeoServer: http://${PUBLIC_HOST}:8079/geoserver"
if [ "$TUNNEL" = "1" ]; then
    echo ""
    echo "  Cloudflare tunnel active — check logs:"
    echo "    make logs-tunnel"
fi
echo ""
