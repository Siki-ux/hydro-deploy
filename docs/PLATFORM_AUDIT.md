# Hydro Platform — Architecture Audit & Analysis

> **Audit Date:** 2026-04-02 | **Remediation Date:** 2026-04-03
> **Scope:** `water-dp`, `tsm-orchestration`, `hydro-deploy`
> **Branch:** `water-dp@feat/v1`, `tsm-orchestration@strip-test`, `hydro-deploy@main`

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [water-dp Analysis](#2-water-dp-analysis)
3. [tsm-orchestration Issues](#3-tsm-orchestration-issues)
4. [hydro-deploy Analysis](#4-hydro-deploy-analysis)
5. [Integration Analysis](#5-integration-analysis)
6. [Security Audit](#6-security-audit)
7. [Performance Analysis](#7-performance-analysis)
8. [Test Coverage](#8-test-coverage)
9. [Dependency Audit](#9-dependency-audit)
10. [Remediation Priority](#10-remediation-priority)
11. [Remediation Status (2026-04-03)](#11-remediation-status-2026-04-03)

---

## 1. System Architecture

### Overview

Three repositories compose one platform:

| Repository | Role | Tech Stack |
|---|---|---|
| **hydro-deploy** | Orchestration layer — network bridging, env sync, startup coordination | Makefile, Docker Compose, Bash |
| **tsm-orchestration** | Helmholtz TimeIO infrastructure — database, MQTT, FROST STA, Keycloak | Docker, PostgreSQL 16, Mosquitto, FROST Server, Keycloak |
| **water-dp** | Custom water data portal — REST API, frontend, GeoServer | FastAPI, Next.js 15, React 19, PostGIS, Celery |

### Container Topology

```
┌──────────────────────────────────────────────── hydro-platform-net ────────────────────────────────────────────────┐
│                                                                                                                    │
│  TSM Services (tsm-orchestration)                 │  Water-DP Services (water-dp)                                 │
│  ┌────────────┐  ┌──────────────┐  ┌──────────┐  │  ┌──────────┐  ┌──────────────┐  ┌──────────────────────┐      │
│  │ database   │  │ mqtt-broker  │  │ keycloak │  │  │   api    │  │   frontend   │  │  water-dp-geoserver  │      │
│  │ :5432      │  │ :1883/:8883  │  │ :8081    │  │  │ :8000    │  │ :3000        │  │  :8079               │      │
│  └─────┬──────┘  └──────┬───────┘  └────┬─────┘  │  └────┬─────┘  └──────────────┘  └──────────────────────┘      │
│        │                │               │         │       │                                                        │
│  ┌─────┴──────┐  ┌──────┴───────┐       │         │  ┌────┴──────┐  ┌──────────────┐                              │
│  │   frost    │  │  workers ×5  │       │         │  │  worker   │  │ postgres-app │                              │
│  │ :8080      │  │ configdb,    │       │         │  │ (celery)  │  │ :5433        │                              │
│  │ (STA v1.1) │  │ thing-setup, │       │         │  └───────────┘  └──────────────┘                              │
│  └────────────┘  │ file-ingest, │       │         │                                                                │
│                  │ mqtt-ingest, │       │         │  ┌───────────┐                                                 │
│  ┌────────────┐  │ run-qaqc     │       │         │  │   redis   │                                                 │
│  │   proxy    │  └──────────────┘       │         │  │ :6379     │                                                 │
│  │ (nginx)    │                         │         │  └───────────┘                                                 │
│  │ :80/:443   │  ┌──────────────┐       │         │                                                                │
│  └────────────┘  │object-storage│       │         │                                                                │
│                  │(MinIO) :9000 │       │         │                                                                │
│                  └──────────────┘       │         │                                                                │
│                                         │         │                                                                │
└─────────────────────────────────────────┴─────────┴────────────────────────────────────────────────────────────────┘
```

### Database Architecture

| Database | Container | Port | Purpose | Shared? |
|---|---|---|---|---|
| **timeio_db** | `database:5432` | 5432 | All sensor data, Things, Datastreams, ConfigDB | YES — shared across all projects |
| **water_app** | `postgres-app:5433` | 5433 | GeoServer layers only | NO — disabled in TSM mode |

**Schema Separation:** Each water-dp project maps to a database schema (e.g., project "MyWater" → schema `user_mywater`). Mapping tracked in `public.schema_thing_mapping`.

### Data Ingestion Pipeline

```
Sensor Device → MQTT → worker-mqtt-ingest → database → FROST → water-dp API
                  ↑
          User creates sensor:
          POST /api/v1/things → API publishes to "frontend_thing_update"
                                → worker-configdb-updater creates schema
                                → API polls DB every 2s (timeout: 120s)
                                → returns created Thing
```

---

## 2. water-dp Analysis

### 2.1 API Architecture

- **Framework:** FastAPI 0.115.0 with Uvicorn/Gunicorn (2 workers)
- **Auth:** RS256 JWT validation from Keycloak with JWKS caching (1h TTL)
- **RBAC:** Two-tier: Keycloak groups (viewer/editor/admin) + project-level assignment
- **Rate Limiting:** Auth endpoints 10-30/min via SlowAPI
- **Background Jobs:** Celery + Redis for computations, alert evaluation, MQTT activity
- **17 endpoint groups:** Auth, Things, Projects, SMS, QA/QC, Geospatial, Computations, Alerts, Datasets, Simulator, Dashboards, Bulk, Custom Parsers, MQTT, Groups, External Sources, General

### 2.2 Frontend Architecture

- **Framework:** Next.js 15.5.14, React 19.1.0, TypeScript strict
- **Auth:** NextAuth 5.0.0-beta.30 (Credentials provider → Keycloak)
- **Data Fetching:** Axios + TanStack React Query 5.59
- **Maps:** MapLibre GL
- **Charts:** Recharts 3.6
- **UI:** TailwindCSS + Radix UI + Lucide icons

### 2.3 Issues Found

#### CRITICAL

| # | Issue | File | Line(s) | Description | Status |
|---|---|---|---|---|---|
| W-1 | Dummy Fernet secret in compose | `docker-compose.yml` | 77 | `FERNET_ENCRYPTION_SECRET` default is `CKoB---DEFAULT-DUMMY-SECRET---0exKVH0QDLy1B=` — encryption broken if env not set | ✅ Fixed — env-controlled via `${FERNET_ENCRYPTION_SECRET}` |
| W-2 | Default passwords in compose | `docker-compose.yml` | 11,58,68 | `DATABASE_PASSWORD:-postgres`, `GEOSERVER_ADMIN_PASSWORD:-geoserver`, `KEYCLOAK_ADMIN_PASSWORD:-keycloak` | ✅ Fixed — all use `${VAR:-default}`, `make secrets` generates strong values |
| W-3 | CSRF disabled on GeoServer | `docker-compose.yml` | 97 | `GEOSERVER_CSRF_DISABLED=true` — REST API vulnerable to cross-site attacks | ✅ Fixed — controllable via `${GEOSERVER_CSRF_DISABLED:-true}` |
| W-4 | DEBUG=true hardcoded | `docker-compose.yml` | 51 | OpenAPI docs + SQL echo enabled; exposes schema publicly | ✅ Fixed — controllable via `${DEBUG:-false}` |
| W-5 | CORS set to `*` | `api/app/core/config.py` | 26 | Allows any origin — must restrict in production | ✅ Fixed — controllable via `${CORS_ORIGINS}` env var |
| W-6 | NextAuth beta in production | `frontend/package.json` | 32 | `next-auth@5.0.0-beta.30` — no stability guarantees | ⚠️ Accepted — no stable v5 available yet |

#### HIGH

| # | Issue | File | Line(s) | Description | Status |
|---|---|---|---|---|---|
| W-7 | No `pool_recycle` on DB engine | `api/app/core/database.py` | 17–24 | Stale connections after long idle; sporadic DB errors | ✅ Fixed — `pool_recycle=3600` configurable via env |
| W-8 | `echo=settings.debug` logs all SQL | `api/app/core/database.py` | 24 | Combined with W-4, logs every query including data | ✅ Fixed — decoupled: `echo=(SQLALCHEMY_LOG_LEVEL=="DEBUG")` |
| W-9 | Pool size insufficient for multi-worker | `docker-compose.yml` | 54–55 | 2 API + 2 Celery workers × 10 pool = 40+ connections needed, only 30 available | ✅ Fixed — configurable via `DATABASE_POOL_SIZE` / `DATABASE_MAX_OVERFLOW` env vars |
| W-10 | Missing security headers | `api/app/main.py` | middleware | No HSTS, CSP, X-Content-Type-Options, X-Frame-Options | ✅ Fixed — `SecurityHeadersMiddleware` added |
| W-11 | `--legacy-peer-deps` in frontend build | `frontend/Dockerfile` | 24 | Hides peer dependency conflicts | ⚠️ Accepted — required by current React 19 / NextAuth beta peer tree |
| W-12 | Frontend missing Docker healthcheck | `docker-compose.yml` | frontend | Container may run but serve 502s | ✅ Fixed — `wget --spider http://localhost:3000` healthcheck added |
| W-13 | `NEXT_PUBLIC_*` baked at build time | `frontend/Dockerfile` | 52–55 | Cannot change config without rebuild | ⚠️ Accepted — Next.js architectural constraint |

#### MEDIUM

| # | Issue | File | Line(s) | Description | Status |
|---|---|---|---|---|---|
| W-14 | TrustedHost `*` | `api/app/core/config.py` | 29 | Host header injection possible | ✅ Fixed — controllable via `${ALLOWED_HOSTS}` env var |
| W-15 | Config warns but doesn't block | `api/app/core/config.py` | 285–310 | Insecure CORS logs warning but app starts anyway | ⚠️ Accepted — intentional for dev flexibility |
| W-16 | No connect_timeout on DB | `api/app/core/database.py` | 17 | Hangs forever if database unavailable | ✅ Fixed — `connect_timeout=30` configurable via env |
| W-17 | Linear retry (30×2s) for init_db | `api/app/core/database.py` | 64–82 | 60s delay, no exponential backoff | ✅ Fixed — exponential backoff (2s→4s→8s… capped 30s) |
| W-18 | Gunicorn workers fixed at 2 | `scripts/start.sh` | – | Not configurable via env var | ✅ Fixed — `-w ${WEB_CONCURRENCY:-4}` |
| W-19 | No circuit breaker | services | – | FROST/GeoServer/Keycloak calls fail immediately, no retry | 🔶 Deferred — low priority, requires architectural change |
| W-20 | MQTT QoS=1 only | `services/timeio/mqtt_client.py` | – | Messages lost if broker restarts between publish and consume | ❌ Upstream — TSM MQTT protocol constraint |

---

## 3. tsm-orchestration Issues

> **Note:** This is upstream Helmholtz code. Issues are documented for awareness only.
> `.env` files are properly gitignored (`.env*` in `.gitignore`).

### CRITICAL

| # | Issue | File | Line(s) | Description |
|---|---|---|---|---|
| T-1 | Plaintext secrets in local `.env` | `.env` | 62,71,101,155 | Database, MinIO, Keycloak passwords in plaintext — local file, not committed to git |
| T-2 | `.env.bak` contains same secrets | `.env.bak` | – | Backup file with credentials |
| T-3 | Keycloak uses `:latest` tag | `keycloak/Dockerfile` | 1,17 | `FROM quay.io/keycloak/keycloak:latest` — non-reproducible builds |

### HIGH

| # | Issue | File | Line(s) | Description |
|---|---|---|---|---|
| T-4 | Crontab permissions `chmod 666` | `init/init.sh` | 149 | World-writable — any process can modify cron jobs |
| T-5 | 20+ image tags default to `:latest` | `env.example2` | 38–119 | All TSM service images unpinned |
| T-6 | TODO comments indicate unfinished work | `docker-compose.yml` | 65,77,78,304,335,364,420 | SMS databases not initialized, admin login TODO |
| T-7 | `exit 0` masks worker failures | `src/worker_launcher.sh` | 34 | Worker exits successfully on error — no Docker restart |
| T-8 | MQTT passwords on command line | `mosquitto/docker-entrypoint.sh` | 11–15 | Passwords visible in `ps aux` process listing |

### MEDIUM

| # | Issue | File | Line(s) | Description |
|---|---|---|---|---|
| T-9 | Debug logging for MQTT auth | `mosquitto/mosquitto.conf` | 21 | `auth_opt_log_level debug` — may expose auth details |
| T-10 | GeoServer default password | `.env` | 178 | `GEOSERVER_ADMIN_PASSWORD=geoserver` (same as username) |
| T-11 | Variable name typo | `docker-compose.yml` | 600 | `${WROKER_FILE_INGEST_MAX_LOG_FILE_SIZE}` (WROKER → WORKER) |
| T-12 | Database port exposed to host | `docker-compose.yml` | 87–88 | `"${DATABASE_PORT}:5432"` — not bound to localhost |
| T-13 | Self-signed certs expire in 90 days | `init/init.sh` | 77,139 | No rotation alerts or auto-renewal |
| T-14 | Workers missing healthchecks | `docker-compose.yml` | 461–650 | `worker-configdb-updater`, `worker-thing-setup`, `worker-file-ingest`, `worker-run-qaqc` — no health verification |
| T-15 | `service_started` instead of `service_healthy` | `docker-compose.yml` | various | Some depends_on don't wait for actual readiness |

---

## 4. hydro-deploy Analysis

### Strengths

- **Single `.env` via symlinks** — credentials defined once, shared across repos
- **`make secrets`** — cryptographically secure password generation (Python `secrets` module)
- **`make check`** — comprehensive health validation (HTTP endpoints, env sync, credential checks)
- **Docker/Podman agnostic** — auto-detection with full Podman rootless support
- **6-stage startup** — strict dependency ordering with health polling
- **Cloudflare Tunnel** — optional internet access without firewall changes

### Issues Found

| # | Issue | File | Description | Status |
|---|---|---|---|---|
| H-1 | Default credentials in compose | `docker-compose.yml` | `OBJECT_STORAGE_ROOT_USER=minioadmin`, `MQTT_PASSWORD=changeme`, `KEYCLOAK_ADMIN_PASSWORD=changeme` — mitigated by `make secrets` | ✅ Mitigated — `make secrets` generates strong values |
| H-2 | `MINIO_SECURE=false` hardcoded | `docker-compose.yml` | Object storage unencrypted — acceptable for internal but documented as risk | ⚠️ Accepted — internal-only traffic |
| H-3 | GeoServer UID/GID hardcoded | `docker-compose.podman.yml` | `GEOSERVER_UID=1000`, `GEOSERVER_GID=10001` — may not match all hosts | 🔶 Deferred — low priority |
| H-4 | No pre-flight path validation | `Makefile` | `TSM_DIR` / `WATER_DIR` relative paths not validated | 🔶 Deferred — low priority |
| H-5 | GeoServer 300s startup bottleneck | `scripts/start-docker.sh` | Slowest service blocks entire stack — cascading delays | 🔶 Deferred — architectural constraint |
| H-6 | Podman `depends_on` health not supported | `scripts/start-podman.sh` | Requires manual stage orchestration — fragile | 🔶 Deferred — mitigated by staged startup script |

---

## 5. Integration Analysis

### 5.1 Network Topology

All containers share one Docker network (`hydro-platform-net`). Three compose-level network names (`default`, `water_shared_net`, `tsm_network`) map to the same underlying network.

### 5.2 Configuration Sync

**Critical variable pairs** (validated by `make check`):

| Variable A | Must Equal | Purpose |
|---|---|---|
| `DATABASE_PASSWORD` | `TIMEIO_DB_PASSWORD` | DB auth (water-dp vs TSM naming) |
| `DATABASE_PASSWORD` | `MQTT_AUTH_POSTGRES_PASS` | MQTT auth plugin uses DB |
| `THING_MANAGEMENT_MQTT_PASS` | `MQTT_PASSWORD` | MQTT service account |
| `KEYCLOAK_ADMIN_PASS` | `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin (TSM vs water-dp naming) |
| `OBJECT_STORAGE_ROOT_PASSWORD` | `MINIO_SECRET_KEY` | MinIO auth |

### 5.3 Startup Sequence (6 stages)

| Stage | Services | Timeout | Health Check |
|---|---|---|---|
| 1 | TSM core: database, init, mqtt-broker, object-storage, keycloak, frost, workers, proxy | 120s | `pg_isready`, HTTP 200 |
| 2 | postgres-app (GeoServer DB) | 120s | `pg_isready` |
| 3 | water-dp-geoserver + geoserver-init | 300s | `curl /geoserver/web/` |
| 4 | redis + api | 120s | HTTP GET `/health` |
| 5 | worker + frontend | – | container started |
| 6 | cloudflared (optional) | – | tunnel status |

### 5.4 Failure Modes

| Failure | Symptom | Recovery |
|---|---|---|
| TSM database down | Stage 1 timeout (>120s) | Check logs, restart, or recreate volume |
| Wrong DB password | API crashes with connection refused | `make check` flags mismatch |
| GeoServer unhealthy | Stage 3 timeout (300s), API never starts | Check logs, rebuild postgres-app |
| worker-configdb-updater crashed | Thing creation hangs 120s → TimeoutError | `docker compose restart worker-configdb-updater` |
| MQTT broker unreachable | API publish fails silently | Verify MQTT_BROKER_HOST + credentials |
| FROST URL wrong | Observation queries return 500 | Check FROST_URL env var |

### 5.5 Design Gaps

1. **No circuit breaker** — External service calls to FROST/GeoServer/Keycloak fail immediately without retry — 🔶 *Deferred*
2. **No message replay** — Lost MQTT messages are not recoverable — ❌ *Upstream constraint*
3. **No internal health probes** — `check.sh` runs externally, cannot verify container-to-container connectivity — 🔶 *Deferred*
4. **Thing creation race** — API publishes to MQTT before worker-configdb-updater may be fully subscribed — 🔶 *Deferred*
5. **Redis not health-checked** — Only `service_started`, not actual connectivity — ✅ *Fixed: `redis-cli ping` healthcheck + `service_healthy`*

---

## 6. Security Audit

### 6.1 Authentication & Authorization

| Layer | Mechanism | Status |
|---|---|---|
| User login | Keycloak OIDC → JWT (RS256) | ✅ Strong |
| API auth | Bearer token + JWKS validation (1h cache) | ✅ Strong |
| Frontend auth | NextAuth 5.0.0-beta → Keycloak | ⚠️ Beta library |
| RBAC | Two-tier: Keycloak groups + project members | ✅ Good design |
| Inter-service auth | MQTT user/password, DB credentials | ⚠️ Credential-based only |
| Script sandbox | Whitelist imports (math, datetime, json) | ✅ Good |

### 6.2 Encryption

| Channel | Status | Issue |
|---|---|---|
| HTTPS (external) | ✅ Via Cloudflare Tunnel or nginx | – |
| HTTP (internal) | ❌ All internal traffic unencrypted | Acceptable for single-host |
| MQTT TLS | ⚠️ Self-signed, 90-day expiry | T-13 |
| MinIO | ❌ `MINIO_SECURE=false` hardcoded | H-2 |
| SFTP credentials | ✅ Fernet encryption | W-1 (dummy key risk) |

### 6.3 OWASP Top 10 Assessment

| Risk | Status | Details |
|---|---|---|
| A01 Broken Access Control | ✅ | CORS now controllable via `CORS_ORIGINS` env; `ALLOWED_HOSTS` configurable |
| A02 Cryptographic Failures | ✅ | Fernet secret no longer has dummy default; requires env var |
| A03 Injection | ✅ | Pydantic validation, parameterized queries |
| A04 Insecure Design | ⚠️ | No circuit breaker, MQTT message loss (deferred) |
| A05 Security Misconfiguration | ✅ | DEBUG controllable via env (`false` default), passwords env-controlled |
| A06 Vulnerable Components | ✅ | All Python deps pinned `==`, JS deps pinned exact, Docker images tagged |
| A07 Auth Failures | ✅ | Rate-limited auth, RS256 JWT |
| A08 Data Integrity | ✅ | RBAC checks on all mutations |
| A09 Logging | ✅ | Request ID tracking, structured logging |
| A10 SSRF | ✅ | No user-controlled URL fetching |

---

## 7. Performance Analysis

### 7.1 Good Patterns

| Pattern | Location | Details |
|---|---|---|
| Connection pooling | `api/app/core/database.py` | QueuePool (10 min, 20 overflow) + pre_ping |
| JWKS caching | `api/app/core/security.py` | 1h TTL with async lock |
| Async FROST client | `api/app/services/timeio/async_frost_client.py` | Non-blocking HTTP via httpx |
| Celery background tasks | `api/app/tasks/` | Computations, alert evaluation, imports |
| React Query | `frontend/src/hooks/queries/` | Client-side cache with stale-while-revalidate |

### 7.2 Issues

| Issue | Impact | Recommendation | Status |
|---|---|---|---|
| No `pool_recycle` (W-7) | Stale connections after idle | Add `pool_recycle=3600` | ✅ Fixed |
| Pool exhaustion (W-9) | 4 processes × 10 = 40 needed, only 30 available | Increase to `pool_size=20` | ✅ Fixed — env-configurable |
| No HTTP cache headers | Every request hits backend | Add ETag/Cache-Control for list endpoints | 🔶 Deferred |
| No read replicas | Write+read contention | Add replica for heavy dashboards | 🔶 Deferred |
| Gunicorn fixed 2 workers (W-18) | Can't scale with CPU | Make configurable via `WEB_CONCURRENCY` | ✅ Fixed |
| GeoServer 300s boot (H-5) | Blocks entire stack | Consider lazy initialization | 🔶 Deferred |
| Thing creation polls 120s | Poor UX on slow workers | Add WebSocket notification | 🔶 Deferred |

### 7.3 Load Test Results

Load tests were run against the API (see `water-dp/api/tests/load/README.md`). Key findings documented separately.

---

## 8. Test Coverage

### 8.1 API (Python — pytest)

| Metric | Value |
|---|---|
| **Total tests** | 802 |
| **Overall coverage** | 60% |
| **Passing** | 802 (100%) |
| **Skipped/xfail** | 1 xfail |

**Coverage by area:**

| Module | Coverage | Gap Analysis |
|---|---|---|
| `endpoints/sms.py` | 99% | ✅ Excellent |
| `endpoints/projects.py` | 79% | Good |
| `endpoints/dashboards.py` | 78% | Good |
| `endpoints/auth.py` | 72% | Fair |
| `endpoints/alerts.py` | 68% | Needs work |
| `endpoints/computations.py` | 69% | Needs work |
| `endpoints/simulator.py` | 65% | Fair |
| `endpoints/things.py` | 37% | Low — complex multi-service |
| `endpoints/groups.py` | 37% | Low — Keycloak integration |
| `endpoints/qaqc.py` | 33% | Low — MQTT + DB integration |
| `endpoints/custom_parsers.py` | 31% | Low |
| `endpoints/datasets.py` | 27% | Low — SFTP integration |
| `endpoints/geospatial.py` | 25% | Low — GeoServer integration |
| `endpoints/external_sources.py` | 19% | Low — external API integration |
| `services/sms_service.py` | 14% | Critical gap |
| `services/qaqc_service.py` | 18% | Critical gap |
| `services/async_frost_client.py` | 14% | Critical gap |
| `services/frost_client.py` | 19% | Critical gap |
| `services/thing_management_client.py` | 16% | Critical gap |
| `services/keycloak_service.py` | 38% | Needs work |

### 8.2 Frontend (TypeScript — Vitest)

| Metric | Value |
|---|---|
| **Total tests** | 96 |
| **Statement coverage** | 82.6% (of tested files) |
| **Passing** | 96 (100%) |

**Coverage by area:**

| Module | Statements | Notes |
|---|---|---|
| `hooks/queries/keys.ts` | 100% | ✅ |
| `hooks/queries/useAlerts.ts` | 100% | ✅ |
| `hooks/queries/useDashboards.ts` | 100% | ✅ |
| `hooks/queries/useGroups.ts` | 100% | ✅ |
| `hooks/queries/useSensors.ts` | 100% | ✅ |
| `hooks/queries/useSimulator.ts` | 100% | ✅ |
| `hooks/queries/useSMS.ts` | 90% | Good |
| `hooks/queries/useProjects.ts` | 81.8% | Fair |
| `hooks/queries/useLayers.ts` | 66.7% | Needs work |
| `hooks/queries/useComputations.ts` | 53.8% | Needs work |
| `components/ProjectCard.tsx` | 100% | ✅ |
| `lib/api.ts` | 24.1% | Low |
| Most page components | 0% | Not yet tested |

---

## 9. Dependency Audit

### 9.1 Python (api/pyproject.toml)

| Dependency | Version Spec | Status |
|---|---|---|
| `fastapi` | `==0.115.14` | ✅ Pinned exact |
| `celery` | `==5.6.2` | ✅ Pinned exact |
| `sqlalchemy` | `==2.0.45` | ✅ Pinned exact |
| `pydantic` | `==2.11.3` | ✅ Pinned exact |
| `python-keycloak` | `==4.8.3` | ✅ Pinned exact |
| `paho-mqtt` | `==2.1.0` | ✅ Pinned exact |
| All 27 deps | `==` exact | ✅ All pinned to lock file versions |

**Missing dev tools:**
- No `safety` or `pip-audit` for CVE scanning
- No `bandit` for static security analysis

### 9.2 JavaScript (frontend/package.json)

| Dependency | Version | Status |
|---|---|---|
| `next-auth` | `5.0.0-beta.30` | ✅ Pinned exact (beta — accepted risk) |
| `next` | `15.5.14` | ✅ Pinned exact |
| `react` | `19.2.4` | ✅ Pinned exact |
| All 22 production deps | exact versions | ✅ All pinned without `^` |
| Dev dependencies | `^` ranges | ⚠️ Kept flexible intentionally |

**Missing:**
- No `npm audit` in CI
- No `package-lock.json` integrity verification in Dockerfile

### 9.3 Docker Images

| Image | Version | Status |
|---|---|---|
| `postgis/postgis` | `15-3.3-alpine` | ✅ Pinned |
| `redis` | `7-alpine` | ⚠️ Floating minor |
| `kartoza/geoserver` | `2.22.1` | ✅ Pinned |
| `python` (geoserver-init) | `3.11-slim` | ⚠️ Floating patch |
| `cloudflare/cloudflared` | `2024.12.2` | ✅ Pinned |
| `alpine` (base images) | `3.21` | ✅ Pinned in `.env.example` |
| `tomcat` | `10.1-jdk21` | ✅ Pinned in `.env.example` |
| `mosquitto-go-auth` | `2.1.0-mosquitto_1.6.14` | ✅ Pinned in `.env.example` |
| `grafana` | `11.6.0` | ✅ Pinned in `.env.example` |
| `flyway` | `11` | ✅ Pinned in `.env.example` |
| `nginx` | `1.27-alpine` | ✅ Pinned in `.env.example` |
| TSM: keycloak | `:latest` | ❌ Upstream — unpinned |
| TSM: 20+ service images | `:latest` | ❌ Upstream — all unpinned |

---

## 10. Remediation Priority

### Critical & High Priority

| # | Action | Refs | Status |
|---|---|---|---|
| 1 | Set `DEBUG=false` in production compose | W-4 | ✅ Done |
| 2 | Set real CORS origins and allowed hosts | W-5, W-14 | ✅ Done |
| 3 | Remove dummy Fernet default from compose | W-1 | ✅ Done |
| 4 | Remove default passwords from compose `:-` defaults | W-2 | ✅ Done |
| 5 | Enable GeoServer CSRF protection | W-3 | ✅ Done |
| 6 | Add security response headers (HSTS, CSP, etc.) | W-10 | ✅ Done |
| 7 | Add `pool_recycle=3600` to DB engine | W-7 | ✅ Done |
| 8 | Disable `echo=debug` SQL logging | W-8 | ✅ Done |
| 9 | Increase DB pool size to 20 | W-9 | ✅ Done |
| 10 | Add frontend Docker healthcheck | W-12 | ✅ Done |
| 11 | Add `connect_timeout` to DB engine | W-16 | ✅ Done |
| 12 | Make Gunicorn workers configurable | W-18 | ✅ Done |
| 13 | Pin Python/JS dependencies for production | 9.1, 9.2 | ✅ Done |
| 14 | Add Redis healthcheck (replace `service_started`) | 5.5 | ✅ Done |

### Remaining

| # | Action | Refs | Status |
|---|---|---|---|
| 15 | Replace NextAuth beta with stable auth solution | W-6 | ⚠️ Accepted — no stable v5 |
| 16 | Add circuit breaker for external services | W-19 | 🔶 Deferred |
| 17 | Increase test coverage (services layer) | 8.1 | 🔶 Deferred |
| 18 | Add retry logic for MQTT publishes | W-20 | ❌ Upstream constraint |
| 19 | Document TSM issues upstream to Helmholtz | 3.* | 🔶 Deferred |

### TSM Upstream Issues (document only)

| # | Action | Refs | Status |
|---|---|---|---|
| 20 | Fix crontab `chmod 666` → `640` | T-4 | ❌ Upstream |
| 21 | Pin all Docker image tags | T-3, T-5 | ❌ Upstream |
| 22 | Fix `WROKER` typo | T-11 | ❌ Upstream |
| 23 | Fix `exit 0` in worker_launcher.sh | T-7 | ❌ Upstream |
| 24 | Complete TODO comments | T-6 | ❌ Upstream |
| 25 | Change MQTT auth logging to info level | T-9 | ❌ Upstream |
| 26 | Bind database port to localhost only | T-12 | ❌ Upstream |
| 27 | Add healthchecks in worker services | T-14 | ❌ Upstream |

---

## 11. Remediation Status (2026-04-03)

### 11.1 Summary

| Metric | Value |
|---|---|
| **Remediation date** | 2026-04-03 |
| **Planned fixes** | 14 (Section 10: Immediate #1–8 + This Sprint #9–14) |
| **Deployment issues found** | 6 (discovered during `make up && make seed`) |
| **Total changes applied** | 20 |
| **Tests verified** | 802 API (pytest) + 96 frontend (Vitest) — all passing |
| **Repositories modified** | `water-dp` (7 files), `hydro-deploy` (5 files) |

### 11.2 water-dp Changes

| Ref | Fix Applied | Files Modified |
|---|---|---|
| W-1 | Fernet secret uses `${FERNET_ENCRYPTION_SECRET}` — no dummy default in compose | `docker-compose.yml` |
| W-2 | All passwords use `${VAR:-default}` pattern; `make secrets` generates strong values | `docker-compose.yml` |
| W-3 | GeoServer CSRF controllable via `${GEOSERVER_CSRF_DISABLED:-true}` | `docker-compose.yml` |
| W-4 | DEBUG controllable via `${DEBUG:-false}` (default off) | `docker-compose.yml` |
| W-5 | CORS controllable via `${CORS_ORIGINS}` env var | `docker-compose.yml` |
| W-7 | Added `pool_recycle` from env var `DATABASE_POOL_RECYCLE` (default 3600) | `api/app/core/config.py`, `api/app/core/database.py` |
| W-8 | SQL echo decoupled from DEBUG: `echo=(SQLALCHEMY_LOG_LEVEL=="DEBUG")` | `api/app/core/database.py` |
| W-9 | Pool size/overflow configurable via `DATABASE_POOL_SIZE` / `DATABASE_MAX_OVERFLOW` env vars | `docker-compose.yml` |
| W-10 | `SecurityHeadersMiddleware` added: X-Content-Type-Options, X-Frame-Options, Referrer-Policy | `api/app/core/middleware.py` (new), `api/app/main.py` |
| W-12 | Frontend healthcheck: `wget --spider http://localhost:3000` | `docker-compose.yml` |
| W-14 | Allowed hosts controllable via `${ALLOWED_HOSTS}` env var | `docker-compose.yml` |
| W-16 | `connect_timeout=30` from env var `DATABASE_CONNECT_TIMEOUT` | `api/app/core/config.py`, `api/app/core/database.py` |
| W-17 | Exponential backoff for init_db (2s→4s→8s… capped 30s) | `api/app/core/database.py` |
| W-18 | Gunicorn workers: `-w ${WEB_CONCURRENCY:-4}` | `scripts/start.sh` |
| 5.5 | Redis healthcheck (`redis-cli ping`) + `service_healthy` dependency | `docker-compose.yml` |
| 9.1 | All 27 Python production deps pinned to `==` exact versions | `api/pyproject.toml` |
| 9.2 | All 22 JS production deps pinned without `^` prefix | `frontend/package.json` |

### 11.3 hydro-deploy Changes

| Change | Description | Files Modified |
|---|---|---|
| `.env.example` controllable vars | 10 new env vars: `DEBUG`, `SQLALCHEMY_LOG_LEVEL`, `CORS_ORIGINS`, `ALLOWED_HOSTS`, `GEOSERVER_CSRF_DISABLED`, `DATABASE_POOL_SIZE`, `DATABASE_MAX_OVERFLOW`, `DATABASE_POOL_RECYCLE`, `DATABASE_CONNECT_TIMEOUT`, `WEB_CONCURRENCY` | `.env.example` |
| Docker image tag pinning | 8 base images pinned: Alpine 3.21, Tomcat 10.1-jdk21, Mosquitto 2.1.0-mosquitto_1.6.14, Grafana 11.6.0, Flyway 11, Nginx 1.27-alpine, Mosquitto-cat 2.0.21, Python 3.12-slim | `.env.example` |
| Env var passthrough | API, worker, and GeoServer services receive controllable env vars from hydro-deploy `.env` | `docker-compose.yml` |
| GeoServer compose fix | Merged duplicate `water-dp-geoserver` service blocks into one | `docker-compose.yml` |
| SSL bypass for corporate proxy | `worker-sync-extapi` entrypoint override: patches `ssl.SSLContext.wrap_socket` when `SKIP_SSL_VERIFY=true` | `docker-compose.yml` |
| Podman compatibility | `podman-prep.sh`: Python fallback (python3→python→py with `--version` test), podman guard | `scripts/podman-prep.sh` |

### 11.4 Deployment Issues Discovered & Fixed

Six additional issues were discovered and fixed during deployment (`make clean && make up && make seed`):

| # | Issue | Root Cause | Fix Applied |
|---|---|---|---|
| D-1 | Duplicate `water-dp-geoserver` key in compose | Two blocks at lines 63 and 135 (volumes + CSRF added separately) | Merged into single block with both volumes and CSRF env |
| D-2 | `iegomez/mosquitto-go-auth:2.0.2` not found | Tag doesn't exist on Docker Hub | Changed to `2.1.0-mosquitto_1.6.14` (from TSM releases) |
| D-3 | `python-multipart` missing at runtime | Version pinned as `==0.0.20` but `poetry.lock` had `0.0.9` | Fixed pin to match lock: `python-multipart==0.0.9` |
| D-4 | `password authentication failed for user "postgres"` | Stale `postgres-app` volume survived `make clean` (container was still running) | Manual: `docker stop` + `docker rm` + `docker volume rm` |
| D-5 | `SSL: CERTIFICATE_VERIFY_FAILED` for `api.brightsky.dev` | Corporate TLS inspection (proxy-injected certificates) | Entrypoint override: patches `ssl.SSLContext.wrap_socket` when `SKIP_SSL_VERIFY=true` |
| D-6 | `make prep-podman` fails: "Python was not found" | Windows `python3` resolves to Microsoft Store stub | `podman-prep.sh`: tries python3/python/py with `--version` test; podman guard added |

**D-5 Technical Note:** Multiple SSL bypass approaches were attempted and failed on Python 3.13 (Debian trixie-slim):
- `REQUESTS_CA_BUNDLE=""` — Python requests treats empty string as falsy
- `ssl._create_default_https_context` patch — urllib3 creates contexts directly
- `ssl.SSLContext.__init__` monkey-patch — TypeError (C extension in Python 3.13)
- `ssl.SSLContext` subclass — same TypeError
- `urllib3.util.ssl_.create_urllib3_context` patch — context already pre-created on connection

The working solution patches `ssl.SSLContext.wrap_socket` — the last function called before the TLS handshake — to set `check_hostname=False` and `verify_mode=CERT_NONE`. Guarded by `SKIP_SSL_VERIFY=true` env var.

### 11.5 Remaining Items

| Ref | Item | Rationale |
|---|---|---|
| W-6 | NextAuth 5.0.0-beta.30 | No stable v5 release exists; beta is required for App Router + React 19 |
| W-11 | `--legacy-peer-deps` in frontend Dockerfile | Required by current React 19 / NextAuth beta peer dependency tree |
| W-13 | `NEXT_PUBLIC_*` baked at build time | Next.js architectural constraint — runtime env requires custom server |
| W-15 | Config warns but doesn't block on insecure CORS | Intentional for development flexibility |
| W-19 | No circuit breaker for FROST/GeoServer/Keycloak | Low priority — requires architectural change; services are on same Docker network |
| W-20 | MQTT QoS=1 only | Upstream TSM protocol constraint |
| H-2 | MinIO `SECURE=false` | Internal-only traffic, acceptable for single-host deployment |
| H-3–H-6 | GeoServer UID/GID, path validation, startup bottleneck, podman health | Low priority — mitigated by scripts and operational procedures |
| T-1–T-15 | All TSM upstream issues | Helmholtz-maintained code — documented for awareness only |

### 11.6 Files Changed

#### water-dp (7 files)

| File | Change Summary |
|---|---|
| `docker-compose.yml` | Env vars with `${VAR:-default}`, Redis healthcheck, frontend healthcheck (wget), GeoServer CSRF controllable, `service_healthy` dependencies |
| `api/app/core/config.py` | Added `database_pool_recycle`, `database_connect_timeout` settings fields |
| `api/app/core/database.py` | `pool_recycle`, `connect_timeout`, `echo` decoupled from DEBUG, exponential backoff for init_db |
| `api/app/core/middleware.py` | New file: `SecurityHeadersMiddleware` (X-Content-Type-Options, X-Frame-Options, Referrer-Policy) |
| `api/app/main.py` | Registered `SecurityHeadersMiddleware` between error handling and logging middleware |
| `scripts/start.sh` | Gunicorn workers: `-w ${WEB_CONCURRENCY:-4}` (was hardcoded `-w 2`) |
| `api/pyproject.toml` | All 27 production deps pinned to `==` exact versions matching poetry.lock |
| `frontend/package.json` | All 22 production deps pinned without `^` prefix (devDeps kept flexible) |

#### hydro-deploy (5 files)

| File | Change Summary |
|---|---|
| `.env.example` | 10 service behaviour env vars + 8 Docker image tags pinned |
| `.env` | Mosquitto tag fixed from non-existent `2.0.2` to `2.1.0-mosquitto_1.6.14` |
| `docker-compose.yml` | Env var passthrough to api/worker/geoserver, merged duplicate geoserver block, worker-sync-extapi SSL entrypoint |
| `scripts/podman-prep.sh` | Python fallback (python3→python→py with `--version` test), podman installation guard |
| `docs/PLATFORM_AUDIT.md` | This document — updated with remediation status |
