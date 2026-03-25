#!/usr/bin/env bash
# scripts/podman-prep.sh
#
# Generates podman-compose-compatible .podman.yml files from the standard
# compose files and ensures the shared Docker network exists.
#
# Run automatically by `make up` when PODMAN=1, or manually:
#   ./scripts/podman-prep.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$DEPLOY_DIR")"

TSM_DIR="$PARENT_DIR/tsm-orchestration"
WATER_DIR="$PARENT_DIR/water-dp"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${CYAN}[podman-prep]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC}          $*"; }

cd "$DEPLOY_DIR"

# ─── Generate .podman.yml files ───────────────────────────────────────────────

info "Generating podman-compatible compose files..."

python3 scripts/podman_prep.py \
    "$TSM_DIR/docker-compose.yml" \
    "$TSM_DIR/docker-compose.podman.yml"

python3 scripts/podman_prep.py \
    "$WATER_DIR/docker-compose.yml" \
    "$WATER_DIR/docker-compose.podman.yml"

python3 scripts/podman_prep.py \
    "$WATER_DIR/docker-compose.tsm.yml" \
    "$WATER_DIR/docker-compose.tsm.podman.yml"

# docker-compose.podman.yml in hydro-deploy is committed and hand-maintained
# (it includes the GeoServer UID fix and explicit MQTT/Keycloak injections).
# Do NOT regenerate it here.

ok "All .podman.yml files generated"

# ─── Ensure network exists ────────────────────────────────────────────────────
#
# Podman does not auto-create networks named in compose files the same way
# Docker does. We pre-create the network so podman-compose doesn't fail.

NETWORK="hydro-platform-net"

if podman network exists "$NETWORK" 2>/dev/null; then
    ok "Network '$NETWORK' already exists"
else
    info "Creating podman network '$NETWORK'..."
    podman network create "$NETWORK"
    ok "Network '$NETWORK' created"
fi

# ─── Fix nginx resolver IP in TSM podman locations ────────────────────────────
#
# The locations.podman/ nginx configs hardcode the Podman DNS server IP.
# The actual IP is the network gateway, which depends on the subnet Podman
# assigned to the network. Query it and patch the locations files.

PODMAN_DNS=$(podman network inspect "$NETWORK" --format '{{(index .Subnets 0).Gateway}}' 2>/dev/null || true)

if [ -n "$PODMAN_DNS" ]; then
    LOCATIONS_DIR="$TSM_DIR/nginx/locations.podman"
    for f in "$LOCATIONS_DIR"/locations*.conf; do
        [ -f "$f" ] || continue
        # Replace any 'resolver A.B.C.D' with the actual gateway.
        sed -i "s/resolver [0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/resolver $PODMAN_DNS/g" "$f"
    done
    ok "nginx resolver set to $PODMAN_DNS in locations.podman/"
fi
