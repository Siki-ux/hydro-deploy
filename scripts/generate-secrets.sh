#!/usr/bin/env bash
# scripts/generate-secrets.sh
#
# Generates cryptographically secure random values for all @generate fields
# in .env. Safe to run on an existing .env — only replaces "changeme" values,
# never overwrites real secrets.
#
# Usage:
#   ./scripts/generate-secrets.sh          # updates .env in place
#   ./scripts/generate-secrets.sh --dry-run  # print what would change

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$(dirname "$SCRIPT_DIR")/.env"
DRY_RUN=false

[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[secrets]${NC} $*"; }
ok()    { echo -e "${GREEN}[set]${NC}     $*"; }
skip()  { echo -e "${YELLOW}[skip]${NC}    $* (already set)"; }

[ -f "$ENV_FILE" ] || { echo -e "${RED}[error]${NC} .env not found. Run: make setup"; exit 1; }

# ─── Generators ───────────────────────────────────────────────────────────────

# 32-byte hex string
hex32() { python3 -c "import secrets; print(secrets.token_hex(32))"; }

# URL-safe base64 (for Fernet keys — must be exactly 32 bytes base64url-encoded)
fernet_key() { python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"; }

# Fallback if cryptography not installed
fernet_key_fallback() {
    python3 -c "import secrets, base64; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())"
}

# Strong passphrase: 4 random words + suffix (easy to type, hard to crack)
passphrase() { python3 -c "
import secrets, string
chars = string.ascii_letters + string.digits
return ''.join(secrets.choice(chars) for _ in range(24))
" 2>/dev/null || python3 -c "import secrets; print(secrets.token_urlsafe(18))"; }

gen_fernet() {
    if python3 -c "from cryptography.fernet import Fernet" 2>/dev/null; then
        fernet_key
    else
        fernet_key_fallback
    fi
}

# ─── Setter ───────────────────────────────────────────────────────────────────

set_var() {
    local KEY="$1"
    local NEW_VALUE="$2"

    # Read current value
    local CURRENT
    CURRENT=$(grep -E "^${KEY}=" "$ENV_FILE" | head -1 | cut -d= -f2-)

    if [ "$CURRENT" = "changeme" ] || [ -z "$CURRENT" ]; then
        if [ "$DRY_RUN" = true ]; then
            ok "$KEY=<new value>"
        else
            # Use sed to replace in-place (works on both Linux and macOS)
            sed -i "s|^${KEY}=.*|${KEY}=${NEW_VALUE}|" "$ENV_FILE"
            ok "$KEY"
        fi
    else
        skip "$KEY"
    fi
}

# ─── Shared database password ─────────────────────────────────────────────────
#
# Several variables must share the same value (e.g. DATABASE_PASSWORD and
# TIMEIO_DB_PASSWORD must both be the same password).

echo ""
info "Generating secrets for hydro-platform..."
echo ""

# One password shared across all DB-related variables
DB_PASS=$(passphrase)
set_var "DATABASE_ADMIN_PASSWORD"  "$DB_PASS"
set_var "DATABASE_PASSWORD"        "$DB_PASS"
set_var "TIMEIO_DB_PASSWORD"       "$DB_PASS"
set_var "MQTT_AUTH_POSTGRES_PASS"  "$DB_PASS"
set_var "KEYCLOAK_DATABASE_PASS"   "$(passphrase)"

# Fernet key (identical in both repos, already shared via .env symlink)
FERNET=$(gen_fernet)
set_var "FERNET_ENCRYPTION_SECRET" "$FERNET"

# MinIO
MINIO_PASS=$(passphrase)
set_var "OBJECT_STORAGE_ROOT_PASSWORD" "$MINIO_PASS"

# MQTT frontendbus user
# @sync — THING_MANAGEMENT_MQTT_PASS and MQTT_PASSWORD must be identical
MQTT_PASS=$(passphrase)
set_var "THING_MANAGEMENT_MQTT_PASS" "$MQTT_PASS"
set_var "MQTT_PASSWORD"              "$MQTT_PASS"
set_var "MQTT_INGEST_PASSWORD"       "$(passphrase)"

# Keycloak admin
# @sync — KEYCLOAK_ADMIN_PASS and KEYCLOAK_ADMIN_PASSWORD must be identical
KC_PASS=$(passphrase)
set_var "KEYCLOAK_ADMIN_PASS"     "$KC_PASS"
set_var "KEYCLOAK_ADMIN_PASSWORD" "$KC_PASS"

# water-dp application secrets
set_var "SECRET_KEY"        "$(hex32)"
AUTH_SECRET=$(hex32)
set_var "AUTH_SECRET"       "$AUTH_SECRET"
set_var "NEXTAUTH_SECRET"   "$AUTH_SECRET"

# Seed admin password
set_var "SEED_ADMIN_PASSWORD" "$(passphrase)"

# GeoServer (optional, default 'geoserver' is fine for dev)
set_var "GEOSERVER_ADMIN_PASSWORD" "$(passphrase)"

echo ""
if [ "$DRY_RUN" = true ]; then
    info "Dry run — no changes made. Remove --dry-run to apply."
else
    echo -e "${GREEN}Done.${NC} All 'changeme' placeholders have been replaced."
    echo ""
    echo "  Verify: grep 'changeme' .env"
    echo "          (should return nothing)"
    echo ""
    echo "  Commit reminder: .env is gitignored. Back it up securely."
fi
echo ""
