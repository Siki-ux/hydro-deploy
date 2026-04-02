# Hydro Platform — Makefile
#
# Works with Docker Compose v2.20+ or Podman.
# Run `make setup` on a fresh clone before anything else.
#
# Podman (rootless) usage — pass PODMAN=1 or export it:
#   make PODMAN=1 up
#   PODMAN=1 make up-tunnel
#
# Auto-detection: if `docker` is not found but `podman` is, PODMAN defaults to 1.

TSM_DIR    ?= ../tsm-orchestration
WATER_DIR  ?= ../water-dp
ENV_FILE   ?= .env

# Load SKIP_SSL_VERIFY from .env (defaults to false if not set or .env missing)
SKIP_SSL_VERIFY ?= $(shell grep -s '^SKIP_SSL_VERIFY=' $(ENV_FILE) | cut -d= -f2 || echo false)
ifeq ($(SKIP_SSL_VERIFY),)
  SKIP_SSL_VERIFY = false
endif

# ─── Engine detection ─────────────────────────────────────────────────────────

# Explicit override wins; otherwise auto-detect.
PODMAN ?= $(shell command -v docker >/dev/null 2>&1 && echo 0 || \
               { command -v podman >/dev/null 2>&1 && echo 1 || echo 0; })

ifeq ($(PODMAN),1)
  # Podman rootless: must pass UID/GID explicitly and use --in-pod false.
  _ENGINE_PREFIX = env UID=$(shell id -u) GID=$(shell id -g)
  _ENGINE        = podman compose --in-pod false -p hydro-platform
  _COMPOSE_FILES = \
    -f $(TSM_DIR)/docker-compose.podman.yml \
    -f $(TSM_DIR)/docker-compose.override.podman.yml \
    -f $(WATER_DIR)/docker-compose.podman.yml \
    -f $(WATER_DIR)/docker-compose.tsm.podman.yml \
    -f docker-compose.podman.yml
  _BUILD_CMD     = podman build
else
  _ENGINE_PREFIX =
  _ENGINE        = docker compose --project-name hydro-platform
  _COMPOSE_FILES = \
    -f $(TSM_DIR)/docker-compose.yml \
    -f $(WATER_DIR)/docker-compose.yml \
    -f $(WATER_DIR)/docker-compose.tsm.yml \
    -f docker-compose.yml
  _BUILD_CMD     = docker build
endif

COMPOSE        = $(_ENGINE_PREFIX) $(_ENGINE) $(_COMPOSE_FILES) --env-file $(ENV_FILE)
COMPOSE_TUNNEL = $(COMPOSE) -f docker-compose.tunnel.yml

.DEFAULT_GOAL := help

# ─── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo ""
	@echo "  Hydro Platform  (engine: $(if $(filter 1,$(PODMAN)),podman,docker))"
	@echo ""
	@echo "  First time:"
	@echo "    make setup            Clone repos, create .env, link configs"
	@echo "    make secrets          Generate secure random passwords into .env"
	@echo "    make update-env       Re-derive URLs after changing PUBLIC_PORT/HOSTNAME"
	@echo "    make build            Build images that need local compilation"
	@echo "    make up               Start the full stack"
	@echo ""
	@echo "  Daily use:"
	@echo "    make up               Start all services"
	@echo "    make up-tunnel        Start with Cloudflare Tunnel (internet access)"
	@echo "    make down             Stop all services"
	@echo "    make restart          Restart all services"
	@echo "    make status           Show container health"
	@echo "    make logs             Follow all logs"
	@echo "    make logs SVC=api     Follow a specific service"
	@echo "    make check            Health check all endpoints"
	@echo ""
	@echo "  Podman:"
	@echo "    make PODMAN=1 up      Force podman (auto-detected if docker absent)"
	@echo "    make prep-podman      Regenerate .podman.yml files (needed after compose edits)"
	@echo ""
	@echo "  Database:"
	@echo "    make migrate          Apply pending Alembic migrations"
	@echo "    make seed             Seed sensors and projects (geoserver-init runs automatically on up)"
	@echo ""
	@echo "  Maintenance:"
	@echo "    make pull             Pull latest images"
	@echo "    make build            (Re)build locally compiled images"
	@echo "    make redeploy-api     Rebuild + recreate api/worker containers"
	@echo "    make redeploy-frontend Rebuild + recreate frontend container"
	@echo "    make clean            Stop + delete all volumes (destructive!)"
	@echo "    make clean-env        Remove .env files so setup+secrets can recreate them"
	@echo "    make prune            Remove unused images and networks"
	@echo ""

# ─── Setup ────────────────────────────────────────────────────────────────────

.PHONY: setup
setup:
	@./scripts/setup.sh

.PHONY: secrets
secrets:
	@./scripts/generate-secrets.sh

# Re-compute derived URLs (PROXY_URL, KEYCLOAK_*, …) after changing
# PUBLIC_HOSTNAME or PUBLIC_PORT in .env.
.PHONY: update-env
update-env:
	@HOST=$$(grep -m1 '^PUBLIC_HOSTNAME=' $(ENV_FILE) | cut -d= -f2-); \
	 PORT=$$(grep -m1 '^PUBLIC_PORT=' $(ENV_FILE) | cut -d= -f2-); \
	 HOST=$${HOST:-localhost}; PORT=$${PORT:-8080}; \
	 if [ "$$PORT" = "80" ]; then BASE="http://$$HOST"; else BASE="http://$$HOST:$$PORT"; fi; \
	 sed -i "s|^PROXY_URL=.*|PROXY_URL=$$BASE|" $(ENV_FILE); \
	 sed -i "s|^KEYCLOAK_EXTERNAL_URL=.*|KEYCLOAK_EXTERNAL_URL=$$BASE/keycloak|" $(ENV_FILE); \
	 sed -i "s|^KEYCLOAK_HOSTNAME_URL=.*|KEYCLOAK_HOSTNAME_URL=$$BASE/keycloak|" $(ENV_FILE); \
	 sed -i "s|^VISUALIZATION_PROXY_URL=.*|VISUALIZATION_PROXY_URL=$$BASE/visualization/|" $(ENV_FILE); \
	 sed -i "s|^STA_PROXY_URL=.*|STA_PROXY_URL=$$BASE/sta/|" $(ENV_FILE); \
	 sed -i "s|^PROXY_PLAIN_PORT_MAPPING=.*|PROXY_PLAIN_PORT_MAPPING=127.0.0.1:$$PORT:80|" $(ENV_FILE); \
	 sed -i "s|^OBJECT_STORAGE_BROWSER_REDIRECT_URL=.*|OBJECT_STORAGE_BROWSER_REDIRECT_URL=http://$$HOST/object-storage/|" $(ENV_FILE); \
	 sed -i "s|^THING_MANAGEMENT_FRONTEND_APP_URL=.*|THING_MANAGEMENT_FRONTEND_APP_URL=http://$$HOST/thing-management|" $(ENV_FILE); \
	 echo "Derived URLs updated (base: $$BASE)"

# ─── Podman prep ──────────────────────────────────────────────────────────────
# Generates .podman.yml variants of all compose files and pre-creates the
# shared network. Must be run once before `make PODMAN=1 up`, and again
# whenever any compose file is edited.

.PHONY: prep-podman
prep-podman:
	@./scripts/podman-prep.sh

# ─── Core stack ───────────────────────────────────────────────────────────────

.PHONY: up
ifeq ($(PODMAN),1)
up: _check-env prep-podman
	@TSM_DIR=$(TSM_DIR) WATER_DIR=$(WATER_DIR) ENV_FILE=$(ENV_FILE) ./scripts/start-podman.sh
else
up: _check-env
	@TSM_DIR=$(TSM_DIR) WATER_DIR=$(WATER_DIR) ENV_FILE=$(ENV_FILE) ./scripts/start-docker.sh
endif

.PHONY: up-tunnel
ifeq ($(PODMAN),1)
up-tunnel: _check-env prep-podman
	@TSM_DIR=$(TSM_DIR) WATER_DIR=$(WATER_DIR) ENV_FILE=$(ENV_FILE) ./scripts/start-podman.sh --tunnel
else
up-tunnel: _check-env
	@TSM_DIR=$(TSM_DIR) WATER_DIR=$(WATER_DIR) ENV_FILE=$(ENV_FILE) ./scripts/start-docker.sh --tunnel
endif

.PHONY: down
down:
	$(COMPOSE) down

.PHONY: down-tunnel
down-tunnel:
	$(COMPOSE_TUNNEL) down

.PHONY: restart
restart:
	$(COMPOSE) restart

# ─── Observability ────────────────────────────────────────────────────────────

.PHONY: status
status:
	$(COMPOSE) ps

.PHONY: logs
logs:
ifdef SVC
	$(COMPOSE) logs -f $(SVC)
else
	$(COMPOSE) logs -f
endif

.PHONY: logs-tunnel
logs-tunnel:
	$(COMPOSE_TUNNEL) logs -f cloudflared

.PHONY: check
check:
	@./scripts/check.sh

# ─── Database ─────────────────────────────────────────────────────────────────

.PHONY: migrate
migrate:
	$(COMPOSE) exec api alembic upgrade head

.PHONY: seed
seed:
	@echo "  Starting test SFTP server..."
	$(COMPOSE) --profile seed up -d test-sftp-server
	@echo "  Seeding water-dp (sensors and projects)..."
	$(COMPOSE) --profile seed run --rm water-dp-seed

# ─── Build & Images ───────────────────────────────────────────────────────────

.PHONY: pull
pull:
	$(COMPOSE) pull --ignore-buildable

# Build water-dp compose definition (standalone, for building only).
# We cd into WATER_DIR so relative paths in the compose file resolve correctly.
# podman-compose resolves build contexts relative to the first -f file's dir;
# running from WATER_DIR avoids the multi-repo relative-path issue.
ifeq ($(PODMAN),1)
  _WATER_BUILD_COMPOSE = cd $(WATER_DIR) && env UID=$(shell id -u) GID=$(shell id -g) podman compose --in-pod false -p hydro-platform -f docker-compose.podman.yml --env-file $(abspath $(ENV_FILE))
else
  _WATER_BUILD_COMPOSE = cd $(WATER_DIR) && docker compose --project-name hydro-platform -f docker-compose.yml --env-file $(abspath $(ENV_FILE))
endif

.PHONY: build
build:
	@echo "Building TSM services..."
	$(COMPOSE) build init keycloak frost cron-scheduler \
		worker-configdb-updater worker-file-ingest worker-grafana-user-orgs \
		worker-monitor-mqtt worker-mqtt-ingest worker-run-qaqc \
		worker-sync-extapi worker-sync-extsftp worker-thing-setup
	@echo "Building water-dp services..."
	$(_WATER_BUILD_COMPOSE) build api worker frontend
	$(_WATER_BUILD_COMPOSE) --profile seed build water-dp-seed

.PHONY: build-api
build-api:
	$(_WATER_BUILD_COMPOSE) build api worker
	$(_WATER_BUILD_COMPOSE) --profile seed build water-dp-seed

.PHONY: build-frontend
build-frontend:
	$(_WATER_BUILD_COMPOSE) build frontend

.PHONY: redeploy-api
redeploy-api: build-api
	$(COMPOSE) up -d --no-deps api worker

.PHONY: redeploy-frontend
redeploy-frontend: build-frontend
	$(COMPOSE) up -d --no-deps frontend

# ─── Maintenance ──────────────────────────────────────────────────────────────

.PHONY: prune
prune:
ifeq ($(PODMAN),1)
	podman image prune -f
	podman network prune -f
else
	docker image prune -f
	docker network prune -f
endif

.PHONY: clean
ifeq ($(PODMAN),1)
clean:
	@echo "WARNING: This will delete ALL data volumes. Type 'yes' to confirm:"
	@read CONFIRM && [ "$$CONFIRM" = "yes" ] || (echo "Aborted." && exit 1)
	-$(COMPOSE) down 2>/dev/null || true
	-podman stop --all --time 5 2>/dev/null || true
	-podman rm --force --all 2>/dev/null || true
	-podman volume ls --format '{{.Name}}' | grep '^hydro-platform_' | xargs -r podman volume rm -f
	@echo "Volumes deleted."
else
clean:
	@echo "WARNING: This will delete ALL data volumes. Type 'yes' to confirm:"
	@read CONFIRM && [ "$$CONFIRM" = "yes" ] || (echo "Aborted." && exit 1)
	$(COMPOSE) --profile seed down -v --remove-orphans
	@echo "Volumes deleted."
endif

# Remove .env files (main + symlinks) so `make setup && make secrets` can recreate them.
.PHONY: clean-env
clean-env:
	@echo "Removing .env files..."
	rm -f $(ENV_FILE)
	rm -f $(TSM_DIR)/.env
	rm -f $(WATER_DIR)/.env
	@echo "Done. Run 'make setup' then 'make secrets' to recreate."

# ─── Guards ───────────────────────────────────────────────────────────────────

.PHONY: _check-env
_check-env:
	@test -f $(ENV_FILE) || (echo "ERROR: $(ENV_FILE) not found. Run: make setup" && exit 1)
	@grep -q "changeme" $(ENV_FILE) && \
		echo "WARNING: .env still contains 'changeme' placeholders. Run: make secrets" || true

# _check-tunnel-token removed: tunnel compose auto-detects quick vs named mode
# based on whether CLOUDFLARE_TUNNEL_TOKEN is set.
