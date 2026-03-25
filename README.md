# Hydro Platform — Deployment Repository

Unified deployment for `tsm-orchestration` + `water-dp`.
One `.env` file. One `make up`. Works with Docker and Podman. Optional internet access via Cloudflare Tunnel.

---

## Repository layout

```
hydro-deploy/                      ← you are here
├── .env.example                   ← template for all variables (both stacks)
├── .env                           ← real config (gitignored, symlinked into repos)
├── docker-compose.yml             ← network bridge layer — Docker
├── docker-compose.podman.yml      ← network bridge layer — Podman (committed, hand-maintained)
├── docker-compose.tunnel.yml      ← Cloudflare Tunnel (optional, Docker + Podman)
├── Makefile                       ← all operations
└── scripts/
    ├── setup.sh                   ← first-time setup
    ├── generate-secrets.sh        ← fill secure passwords into .env
    ├── check.sh                   ← health check all services and endpoints
    ├── podman-prep.sh             ← generate .podman.yml files + create network
    └── podman_prep.py             ← Python script called by podman-prep.sh

../tsm-orchestration/              ← cloned by setup.sh, .env is a symlink here
../water-dp/                       ← cloned by setup.sh, .env is a symlink here
```

The `.env` symlink is the key mechanism: both repos' `env_file: .env` directives
read the deployment repo's `.env`, so credentials are defined exactly once.

---

## First-time setup

```bash
git clone <this-repo> hydro-deploy
cd hydro-deploy

# 1. Clone both repos, create .env, create symlinks, build keycloak image
make setup

# 2. Generate cryptographically secure passwords
make secrets

# 3. Review .env — adjust PUBLIC_HOSTNAME, image tags, etc.
$EDITOR .env

# 4. Build locally compiled images (keycloak, water-dp api/frontend)
make build

# 5. Start the stack
make up

# 6. Apply database migrations (first time or after schema changes)
make migrate
```

Access points after `make up` (with `PUBLIC_HOSTNAME=localhost`):

| Service       | URL                                          |
|---------------|----------------------------------------------|
| Hydro Portal  | http://localhost/portal                      |
| water-dp API  | http://localhost/water-api/api/v1/docs       |
| FROST API     | http://localhost/sta/v1.1                    |
| Keycloak      | http://localhost:8081                        |
| GeoServer     | http://localhost:8079/geoserver              |
| MinIO console | http://localhost:9001                        |

---

## Podman (rootless)

This machine runs Podman instead of Docker. The Makefile auto-detects which
engine to use: if `docker` is not available but `podman` is, `PODMAN=1` is set
automatically. You can also set it explicitly.

### Why Podman needs extra handling

Podman-compose has several differences from Docker Compose that require
pre-processing the compose files before use:

| Issue | Cause | Fix |
|---|---|---|
| `environment:` list format | podman-compose fails to parse `- KEY=VALUE` lists | `podman_prep.py` converts them to dict format |
| `depends_on:` on disabled services | podman-compose does not honour `profiles:` and chokes on the reference | `podman_prep.py` removes disabled services and their `depends_on` entries |
| `profiles: [disabled]` | podman-compose ignores profiles, so `postgres-app` would start | Service is removed entirely from the processed file |
| Shared network | Podman does not auto-create named networks the same way Docker does | `podman-prep.sh` runs `podman network create hydro-platform-net` |
| GeoServer UID | Rootless Podman starts containers as the host user UID, breaking GeoServer's entrypoint which expects root | `docker-compose.podman.yml` sets explicit `GEOSERVER_UID`/`GEOSERVER_GID` |
| UID/GID env vars | Rootless Podman needs explicit UID/GID for volume permissions | Makefile prefixes the command with `env UID=$(id -u) GID=$(id -g)` |
| `--in-pod false` | Podman-compose default puts all containers in a pod, which breaks networking | `--in-pod false` flag keeps them as standalone containers |

### Podman first-time setup

Same as the Docker setup, but pass `PODMAN=1`:

```bash
make setup          # same — setup.sh works for both engines

make secrets        # same

make PODMAN=1 build # uses `podman build` instead of `docker build`

make PODMAN=1 up    # auto-runs podman-prep.sh, then starts the stack

make migrate        # same — runs alembic inside the api container
```

Or export `PODMAN=1` once for the whole session:

```bash
export PODMAN=1
make build
make up
make migrate
```

### How the Podman compose stack is assembled

`make PODMAN=1 up` first runs `scripts/podman-prep.sh`, which:

1. Calls `podman_prep.py` on each of the four source compose files, producing:
   ```
   ../tsm-orchestration/docker-compose.podman.yml
   ../water-dp/docker-compose.podman.yml
   ../water-dp/docker-compose.tsm.podman.yml
   docker-compose.podman.yml               ← already committed, not regenerated
   ```
2. Creates the `hydro-platform-net` network if it does not exist.

Then the full command becomes:

```
env UID=<your-uid> GID=<your-gid>  \
  podman compose --in-pod false -p hydro-platform \
  -f ../tsm-orchestration/docker-compose.podman.yml \
  -f ../water-dp/docker-compose.podman.yml \
  -f ../water-dp/docker-compose.tsm.podman.yml \
  -f docker-compose.podman.yml \
  [ -f docker-compose.tunnel.yml ]
  --env-file .env \
  up -d
```

### Regenerating after compose file edits

The `.podman.yml` files in the sibling repos (`tsm-orchestration/` and
`water-dp/`) are generated files and are gitignored. Whenever you edit any
standard compose file, regenerate them:

```bash
make prep-podman
# or implicitly:
make PODMAN=1 up    # prep-podman runs automatically before up
```

`docker-compose.podman.yml` in this repo is committed and hand-maintained
(it contains the GeoServer UID fix which is not auto-generated).

### Podman common operations

All standard `make` targets work with `PODMAN=1`:

```bash
make PODMAN=1 up               # start all services
make PODMAN=1 up-tunnel        # start with Cloudflare Tunnel
make PODMAN=1 down             # stop all services
make PODMAN=1 restart          # restart all services
make PODMAN=1 status           # show container status
make PODMAN=1 logs             # follow all logs
make PODMAN=1 logs SVC=api     # follow a specific service
make PODMAN=1 build            # build images (uses podman build)
make PODMAN=1 build-api        # rebuild api + worker only
make PODMAN=1 migrate          # apply Alembic migrations
make PODMAN=1 seed             # seed test data
make PODMAN=1 prune            # remove unused images/networks
make PODMAN=1 clean            # ⚠ stop + delete all volumes
make prep-podman               # regenerate .podman.yml files manually
```

---

## Internet access via Cloudflare Tunnel

Cloudflare Tunnel gives HTTPS access from the internet without opening firewall
ports or having a static IP. Works identically with Docker and Podman.

Traffic flow:

```
Browser (internet)
  → Cloudflare edge
    → cloudflared container
      → proxy (TSM nginx)
        → all services
```

### One-time tunnel configuration

1. Go to [Cloudflare Zero Trust](https://one.dash.cloudflare.com) → **Networks → Tunnels → Create tunnel**
2. Name it `hydro-platform`
3. Under **Public Hostnames**, add routes:

   | Subdomain | Domain          | Service           |
   |-----------|-----------------|-------------------|
   | *(blank)* | your-domain.com | `http://proxy:80` |

   This sends all traffic through TSM's nginx, which routes to the right service.
   Alternatively add per-service subdomains:

   | Subdomain | Domain          | Service                         |
   |-----------|-----------------|---------------------------------|
   | portal    | your-domain.com | `http://water-dp-frontend:3000` |
   | api       | your-domain.com | `http://water-dp-api:8000`      |
   | keycloak  | your-domain.com | `http://keycloak:8080`          |

4. Copy the **Tunnel Token** shown on the connector page.

5. Add to `.env`:
   ```
   PUBLIC_HOSTNAME=your-domain.com
   KEYCLOAK_EXTERNAL_URL=https://your-domain.com
   CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoiM...
   ```

6. Start with tunnel:
   ```bash
   make up-tunnel           # Docker
   make PODMAN=1 up-tunnel  # Podman
   ```

7. Verify:
   ```bash
   make check
   make logs-tunnel
   ```

---

## Common operations (Docker)

```bash
make up              # start all services
make up-tunnel       # start with Cloudflare Tunnel
make down            # stop all services
make restart         # restart all services
make status          # show container health table
make logs            # follow all logs
make logs SVC=api    # follow a specific service (e.g. water-dp-api)
make check           # health check: containers + endpoints + .env consistency

make migrate         # apply pending Alembic migrations
make seed            # seed test sensors and projects

make pull            # pull latest registry images
make build           # rebuild all locally compiled images
make build-api       # rebuild only api + worker
make build-frontend  # rebuild only frontend

make clean           # ⚠ stop + delete all volumes (data loss!)
make prune           # remove unused Docker images and networks
```

---

## How the Docker compose stack is assembled

Every `make up` (or `make up-tunnel`) runs:

```
docker compose \
  --project-name hydro-platform \
  -f ../tsm-orchestration/docker-compose.yml \   ← TSM services
  -f ../water-dp/docker-compose.yml \            ← water-dp services
  -f ../water-dp/docker-compose.tsm.yml \        ← water-dp TSM overrides
  -f docker-compose.yml \                        ← network bridge (this repo)
  [ -f docker-compose.tunnel.yml ]               ← tunnel (optional)
  --env-file .env
```

`docker-compose.yml` (this repo) does three things:
1. Maps both network names (`water_shared_net` and `tsm_network`) to the same
   Docker network `hydro-platform-net`, so all containers can reach each other.
2. Disables `postgres-app` (water-dp's standalone DB) — TSM's `database` is used.
3. Injects `MINIO_URL=object-storage:9000` into water-dp services so MinIO
   is always reachable by container name regardless of `.env` values.

---

## Environment variable reference

Variables marked **@sync** appear under two different names in the two repos.
Both names are in `.env` so both stacks read the value they expect.

| Variable(s)                                         | Used by        | Note    |
|-----------------------------------------------------|----------------|---------|
| `DATABASE_PASSWORD` / `TIMEIO_DB_PASSWORD`          | both           | @sync   |
| `THING_MANAGEMENT_MQTT_PASS` / `MQTT_PASSWORD`      | TSM / water-dp | @sync   |
| `KEYCLOAK_ADMIN_PASS` / `KEYCLOAK_ADMIN_PASSWORD`   | TSM / water-dp | @sync   |
| `FERNET_ENCRYPTION_SECRET`                          | both           |         |
| `OBJECT_STORAGE_ROOT_PASSWORD` / `MINIO_SECRET_KEY` | both           | @sync   |

`make check` verifies that all @sync pairs are identical.

---

## Updating to a new release

```bash
# Pull latest code
cd ../tsm-orchestration && git pull
cd ../water-dp && git pull
cd ../hydro-deploy

# Update image tags in .env if needed
$EDITOR .env

# Pull new registry images
make pull            # Docker
# make PODMAN=1 pull  # Podman

# Rebuild locally compiled images
make build           # Docker
# make PODMAN=1 build  # Podman

# Restart
make down && make up
# make PODMAN=1 down && make PODMAN=1 up  # Podman

# Apply any new migrations
make migrate
```

---

## Troubleshooting

**Container stuck in "starting"**
```bash
make status           # see which container is unhealthy
docker logs <name>    # Docker
podman logs <name>    # Podman
```

**`MINIO_URL` connection refused**
`docker-compose.yml` and `docker-compose.podman.yml` both force
`MINIO_URL=object-storage:9000`. If you see this error, the `object-storage`
container is not yet healthy. Wait 30 seconds and run `make check` again.

**Keycloak redirecting to wrong URL**
Set `KEYCLOAK_EXTERNAL_URL` to the URL the browser uses (not an internal hostname).
For tunnel: `https://your-domain.com`, for local: `http://localhost:8081`.

**@sync variables differ**
Run `make check` — it lists which pairs are out of sync.
Edit `.env` to make them match, then `make restart`.

**Cloudflare Tunnel not connecting**
```bash
make logs-tunnel    # look for auth errors or "failed to connect"
```
Verify `CLOUDFLARE_TUNNEL_TOKEN` in `.env` is the full token from the dashboard.

**Podman: `environment` parse error**
Means a compose file was edited but `.podman.yml` files were not regenerated.
```bash
make prep-podman
```

**Podman: GeoServer fails to start (permission error)**
The `GEOSERVER_UID`/`GEOSERVER_GID` override in `docker-compose.podman.yml`
must match values that the kartoza/geoserver image accepts. Default `1000`/`10001`
works for most setups. If your host UID differs, adjust and restart:
```bash
$EDITOR docker-compose.podman.yml   # change GEOSERVER_UID
make PODMAN=1 restart
```

**Podman: network not found**
```bash
make prep-podman    # recreates the network if missing
```

**Podman: volume permission denied**
Rootless Podman maps container UIDs to subuid ranges. If a volume was
previously created by root (Docker), Podman can't write to it.
```bash
make PODMAN=1 clean   # delete old volumes (data loss!)
make PODMAN=1 up
```
