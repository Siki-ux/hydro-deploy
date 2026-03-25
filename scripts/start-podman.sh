#!/usr/bin/env bash
# scripts/start-podman.sh
#
# Stage-aware startup for the Hydro Platform under rootless Podman.
#
# podman-compose 1.x does not implement "wait for health then start":
# containers whose depends_on conditions are not yet met are left in "Created"
# state and never auto-started later. This script polls container health and
# starts each water-dp stage manually once its dependencies are confirmed.
#
# Startup order:
#   Stage 1: TSM stack (database, mqtt-broker, object-storage, keycloak,
#            frost, visualization, workers, proxy ...)
#   Stage 2: postgres-app  (GeoServer's dedicated DB)
#   Stage 3: water-dp-geoserver
#   Stage 4: api + redis
#   Stage 5: worker + frontend + geoserver-init (one-shot schema seeder)
#   Stage 6: cloudflared  (only with --tunnel)
#
# Usage:
#   ./scripts/start-podman.sh [--tunnel]
#
# Called by:
#   make PODMAN=1 up
#   make PODMAN=1 up-tunnel

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

_BASE="env UID=$(id -u) GID=$(id -g) podman compose --in-pod false -p hydro-platform"
_FILES="\
  -f $TSM_DIR/docker-compose.podman.yml \
  -f $TSM_DIR/docker-compose.override.podman.yml \
  -f $WATER_DIR/docker-compose.podman.yml \
  -f $WATER_DIR/docker-compose.tsm.podman.yml \
  -f $DEPLOY_DIR/docker-compose.podman.yml"

COMPOSE="$_BASE $_FILES --env-file $ENV_FILE"
if [ "$TUNNEL" = "1" ]; then
    COMPOSE_TUNNEL="$COMPOSE -f $DEPLOY_DIR/docker-compose.tunnel.yml"
else
    COMPOSE_TUNNEL="$COMPOSE"
fi

# ─── Health polling ───────────────────────────────────────────────────────────

# wait_healthy <container_name> [<timeout_seconds>]
# Polls until the container reports "healthy" or times out.
wait_healthy() {
    local container="$1"
    local timeout="${2:-300}"
    local waited=0
    local status

    info "Waiting for $container to be healthy (up to ${timeout}s)..."
    while [ "$waited" -lt "$timeout" ]; do
        status=$(podman inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")
        case "$status" in
            healthy)
                ok "$container is healthy"
                return 0
                ;;
            unhealthy)
                die "$container reported unhealthy — check logs: podman logs $container"
                ;;
        esac
        sleep 5
        waited=$((waited + 5))
    done
    die "Timed out waiting for $container to become healthy after ${timeout}s"
}

# ─── Stage 1: Start the full stack ────────────────────────────────────────────
# podman-compose creates all containers. Water-dp services that have
# depends_on conditions not yet satisfied are left in "Created" state.
# TSM services (no blocking deps) start immediately.

info "Starting stack (TSM first; water-dp services will follow in stages)..."
$COMPOSE_TUNNEL up -d

# ─── Stage 2: postgres-app ────────────────────────────────────────────────────
# postgres-app depends_on proxy (service_healthy) in docker-compose.podman.yml,
# so it is in Created state. Start it once proxy is up.

wait_healthy hydro-platform_proxy_1 300

info "Starting postgres-app (GeoServer dedicated DB)..."
podman start water-dp-postgres 2>/dev/null || warn "water-dp-postgres already running"
wait_healthy water-dp-postgres 120

# ─── Stage 3: GeoServer ───────────────────────────────────────────────────────

info "Starting water-dp-geoserver..."
podman start water-dp-geoserver 2>/dev/null || warn "water-dp-geoserver already running"
wait_healthy water-dp-geoserver 300

# ─── Stage 4: api + redis ─────────────────────────────────────────────────────

info "Starting api and redis..."
podman start water-dp-api water-dp-redis 2>/dev/null || warn "api/redis already running"
wait_healthy water-dp-api 120

# ─── Stage 5: worker + frontend + geoserver-init ──────────────────────────────

info "Starting worker, frontend and geoserver-init..."
podman start water-dp-worker water-dp-frontend water-dp-geoserver-init 2>/dev/null \
    || warn "worker/frontend/geoserver-init already running"

# ─── Stage 6: cloudflared ─────────────────────────────────────────────────────

if [ "$TUNNEL" = "1" ]; then
    info "Starting cloudflared tunnel..."
    podman start hydro-cloudflared 2>/dev/null || warn "hydro-cloudflared already running"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

PUBLIC_HOST=$(grep "^PUBLIC_HOSTNAME" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || echo "localhost")

echo ""
ok "Stack started (podman). Access points:"
echo "    Portal:    http://${PUBLIC_HOST}/portal"
echo "    API docs:  http://${PUBLIC_HOST}/water-api/api/v1/docs"
echo "    Keycloak:  http://${PUBLIC_HOST}:8081"
echo "    GeoServer: http://${PUBLIC_HOST}:8079/geoserver"
if [ "$TUNNEL" = "1" ]; then
    echo ""
    echo "  Cloudflare tunnel active — check logs:"
    echo "    make PODMAN=1 logs-tunnel"
fi
echo ""
