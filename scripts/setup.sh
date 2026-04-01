#!/usr/bin/env bash
# scripts/setup.sh — First-time setup for hydro-deploy
# Run from the hydro-deploy/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
PARENT_DIR="$(dirname "$DEPLOY_DIR")"

TSM_DIR="$PARENT_DIR/tsm-orchestration"
WATER_DIR="$PARENT_DIR/water-dp"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[setup]${NC} $*"; }
ok()      { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()     { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# ─── Prerequisites ────────────────────────────────────────────────────────────

check_prereqs() {
    info "Checking prerequisites..."

    # Engine detection: prefer docker, fall back to podman
    if command -v docker >/dev/null 2>&1; then
        _SETUP_ENGINE=docker
        _SETUP_BUILD="docker build"
        if ! docker compose version >/dev/null 2>&1; then
            die "Docker Compose v2 plugin not found. Run: sudo apt install docker-compose-plugin"
        fi
        ok "Engine: Docker $(docker --version | grep -oP '[\d.]+' | head -1), Compose $(docker compose version --short)"
    elif command -v podman >/dev/null 2>&1; then
        _SETUP_ENGINE=podman
        _SETUP_BUILD="podman build"
        if ! command -v podman-compose >/dev/null 2>&1 && ! podman compose version >/dev/null 2>&1; then
            die "podman-compose not found. Install it: pip install podman-compose"
        fi
        ok "Engine: Podman $(podman --version | grep -oP '[\d.]+' | head -1)"
        warn "Podman detected — use 'make PODMAN=1 ...' for all operations."
    else
        die "Neither docker nor podman found. Install one of them first."
    fi

    command -v git >/dev/null 2>&1 || die "git not found."

    # Detect Python: prefer python3, fall back to python (Windows).
    # On Windows the Microsoft Store stub `python3.exe` exists on PATH but
    # fails with "Python was not found", so verify the command actually works.
    if python3 --version >/dev/null 2>&1; then
        PYTHON=python3
    elif python --version >/dev/null 2>&1; then
        PYTHON=python
    else
        die "python3 (or python) not found."
    fi
    ok "Python: $($PYTHON --version)"
}

# ─── Clone repos ─────────────────────────────────────────────────────────────

clone_repos() {
    info "Checking source repositories..."

    if [ ! -d "$TSM_DIR" ]; then
        info "Cloning tsm-orchestration into $TSM_DIR..."
        read -rp "  tsm-orchestration git URL: " TSM_URL
        git clone "$TSM_URL" "$TSM_DIR"
        ok "Cloned tsm-orchestration"
    else
        ok "tsm-orchestration found at $TSM_DIR"
    fi

    if [ ! -d "$WATER_DIR" ]; then
        info "Cloning water-dp into $WATER_DIR..."
        read -rp "  water-dp git URL: " WATER_URL
        git clone "$WATER_URL" "$WATER_DIR"
        ok "Cloned water-dp"
    else
        ok "water-dp found at $WATER_DIR"
    fi
}

# ─── Environment file ─────────────────────────────────────────────────────────

setup_env() {
    info "Setting up .env..."

    if [ ! -f "$DEPLOY_DIR/.env" ]; then
        cp "$DEPLOY_DIR/.env.example" "$DEPLOY_DIR/.env"
        ok "Created .env from .env.example"
        warn "Run 'make secrets' to generate secure passwords before starting."
    else
        ok ".env already exists — skipping copy"
    fi
}

# ─── Symlinks ─────────────────────────────────────────────────────────────────
#
# Both repos' compose files use `env_file: .env` which resolves relative to
# the compose file's directory. By symlinking each repo's .env to the
# deployment repo's .env, we get a single source of truth.

create_symlinks() {
    info "Creating .env symlinks..."

    local TARGET="$DEPLOY_DIR/.env"

    for REPO_DIR in "$TSM_DIR" "$WATER_DIR"; do
        local LINK="$REPO_DIR/.env"
        local REL_TARGET

        # Compute relative path from the repo dir to the deploy dir .env
        # (works on Linux; macOS users may need coreutils realpath)
        REL_TARGET="$($PYTHON -c "import os; print(os.path.relpath('$TARGET', '$REPO_DIR'))")"

        if [ -L "$LINK" ]; then
            local EXISTING_TARGET
            EXISTING_TARGET="$(readlink "$LINK")"
            if [ "$EXISTING_TARGET" = "$REL_TARGET" ]; then
                ok "$(basename "$REPO_DIR")/.env symlink already correct"
                continue
            else
                warn "$(basename "$REPO_DIR")/.env is a symlink to '$EXISTING_TARGET', updating..."
                rm "$LINK"
            fi
        elif [ -f "$LINK" ]; then
            warn "$(basename "$REPO_DIR")/.env is a real file — backing up to .env.bak and replacing with symlink"
            mv "$LINK" "${LINK}.bak"
        fi

        ln -s "$REL_TARGET" "$LINK"
        ok "$(basename "$REPO_DIR")/.env → $REL_TARGET"
    done
}

# ─── Build keycloak ───────────────────────────────────────────────────────────
#
# TSM's keycloak service uses a locally built image (tsm-keycloak:local).
# It must be built before `docker compose up`.

build_keycloak() {
    if $_SETUP_ENGINE image inspect tsm-keycloak:local >/dev/null 2>&1; then
        ok "tsm-keycloak:local image already exists"
    else
        info "Building tsm-keycloak:local (required by TSM keycloak service)..."
        $_SETUP_BUILD -t tsm-keycloak:local "$TSM_DIR/keycloak"
        ok "Built tsm-keycloak:local"
    fi
}

# ─── Derive URLs from PUBLIC_HOSTNAME + PUBLIC_PORT ──────────────────────────
#
# Docker Compose .env files do NOT support self-referencing variables.
# This function computes all URL-typed variables from PUBLIC_HOSTNAME and
# PUBLIC_PORT so the user only ever edits those two values.

resolve_derived_env() {
    local ENV="$DEPLOY_DIR/.env"
    info "Computing derived URLs from PUBLIC_HOSTNAME / PUBLIC_PORT..."

    local HOST PORT BASE_URL
    HOST="$(grep -m1 '^PUBLIC_HOSTNAME=' "$ENV" | cut -d= -f2-)"
    PORT="$(grep -m1 '^PUBLIC_PORT=' "$ENV" | cut -d= -f2-)"
    HOST="${HOST:-localhost}"
    PORT="${PORT:-8080}"

    # Omit :80 from URLs (standard HTTP port).
    if [ "$PORT" = "80" ]; then
        BASE_URL="http://${HOST}"
    else
        BASE_URL="http://${HOST}:${PORT}"
    fi

    # List of derived replacements: VARNAME <tab> VALUE
    local -a DERIVED=(
        "PROXY_URL=${BASE_URL}"
        "KEYCLOAK_EXTERNAL_URL=${BASE_URL}/keycloak"
        "KEYCLOAK_HOSTNAME_URL=${BASE_URL}/keycloak"
        "VISUALIZATION_PROXY_URL=${BASE_URL}/visualization/"
        "STA_PROXY_URL=${BASE_URL}/sta/"
        "PROXY_PLAIN_PORT_MAPPING=127.0.0.1:${PORT}:80"
        "OBJECT_STORAGE_BROWSER_REDIRECT_URL=http://${HOST}/object-storage/"
        "THING_MANAGEMENT_FRONTEND_APP_URL=http://${HOST}/thing-management"
    )

    for entry in "${DERIVED[@]}"; do
        local KEY="${entry%%=*}"
        local VAL="${entry#*=}"
        if grep -q "^${KEY}=" "$ENV"; then
            sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "$ENV"
        fi
    done

    ok "Derived URLs set (base: ${BASE_URL})"
}

# ─── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Setup complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Next steps:"
    echo ""
    echo "  1. Generate secure passwords:"
    echo "       make secrets"
    echo ""
    echo "  2. Review and edit .env if needed:"
    echo "       \$EDITOR .env"
    echo ""
    echo "  3. For internet access via Cloudflare Tunnel:"
    echo "       - Create a tunnel at https://one.dash.cloudflare.com"
    echo "       - Set CLOUDFLARE_TUNNEL_TOKEN in .env"
    echo "       - Use: make up-tunnel"
    echo ""
    echo "  4. Build locally compiled images:"
    echo "       make build"
    echo ""
    echo "  5. Start the stack:"
    echo "       make up          # local only"
    echo "       make up-tunnel   # with internet tunnel"
    echo ""
    echo "  6. Apply database migrations:"
    echo "       make migrate"
    echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

cd "$DEPLOY_DIR"

check_prereqs
clone_repos
setup_env
resolve_derived_env
create_symlinks
build_keycloak
print_summary
