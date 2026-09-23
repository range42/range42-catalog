# misp-standalone

A self-contained, auto-provisioned MISP deployment via Docker Compose.
After a single `docker compose up --build`, the instance is ready to consume programmatically: reader and writer API keys are generated and waiting in a mounted volume.

---

## Prerequisites

- Docker Engine 24+ with the Compose plugin (`docker compose version`)
- Internet access during the first build (pulls Ubuntu 24.04, clones MISP from GitHub)

---

## Quick start

```bash
# 1. Copy and edit configuration
cp .env.example .env
$EDITOR .env   # set passwords (≥12 chars), base URL, org name, salt

# 2. Build and start — first build takes 10–20 min (git clone + submodules + apt)
docker compose up --build -d

# 3. Watch progress — bootstrap takes 3–5 min after the build finishes
docker compose logs -f misp
docker compose logs -f provisioner
```

MISP is ready when `docker compose logs provisioner` shows **"Provisioning complete."**

---

## Retrieve API keys

```bash
# Print to stdout
docker compose exec misp cat /keys/api-keys.txt

# Copy to local file
docker compose cp misp:/keys/api-keys.txt ./api-keys.txt
```

`api-keys.txt` contains:

| Variable | Role |
|----------|------|
| `MISP_ADMIN_KEY` | Site Admin (full access) |
| `MISP_ADMIN2_KEY` | Second Site Admin (if configured) |
| `MISP_READER_KEY` | Read Only |
| `MISP_WRITER_KEY` | Publisher (create + publish events) |

---

## Default accounts

| Account | E-mail | Role | Role ID |
|---------|--------|------|---------|
| Admin   | `MISP_ADMIN_EMAIL` | Site Admin | 1 |
| Reader  | `MISP_READER_EMAIL` | Read Only | 6 |
| Writer  | `MISP_WRITER_EMAIL` | Publisher | 4 |

Passwords are set via the corresponding `_PASSWORD` variables in `.env`.
**Passwords must be at least 12 characters** (MISP default policy enforced at user creation time).

---

## Configuration reference

| Variable | Description | Default |
|----------|-------------|---------|
| `MISP_VERSION` | MISP git tag to build from | `v2.5.37` |
| `MISP_PORT` | Host port for the MISP web UI | `8080` |
| `MISP_BASEURL` | URL advertised in events/feeds/e-mails | `http://localhost:8080` |
| `MISP_ORG` | Default organisation name | `Default Organisation` |
| `MISP_SALT` | Security salt — generate with `openssl rand -hex 32` | — |
| `MISP_ADMIN_EMAIL` / `MISP_ADMIN_PASSWORD` | Primary admin credentials | see `.env.example` |
| `MISP_ADMIN2_EMAIL` / `MISP_ADMIN2_PASSWORD` | Optional second admin (leave blank to skip) | — |
| `MISP_READER_EMAIL` / `MISP_READER_PASSWORD` | Read Only user | see `.env.example` |
| `MISP_WRITER_EMAIL` / `MISP_WRITER_PASSWORD` | Publisher user | see `.env.example` |
| `MISP_DB_*` / `DB_*` | MariaDB connection settings | see `.env.example` |
| `REDIS_HOST` / `REDIS_PORT` | Redis connection | `redis` / `6379` |

---

## Build and push

```bash
# Build and tag for a registry
docker build \
  --target runtime \
  --build-arg MISP_VERSION=v2.5.37 \
  -t registry.example.com/range42/misp-standalone:v2.5.37 \
  -t registry.example.com/range42/misp-standalone:latest \
  .

# Push
docker push registry.example.com/range42/misp-standalone:v2.5.37
docker push registry.example.com/range42/misp-standalone:latest
```

---

## Volumes

| Volume | Contents |
|--------|----------|
| `db-data` | MariaDB data files |
| `misp-files` | MISP uploaded files |
| `misp-attachments` | Event attachments |
| `misp-logs` | MISP application logs |
| `keys` | Bootstrap auth-key and final `api-keys.txt` |

Volumes persist across `docker compose down`. To fully reset:

```bash
docker compose down -v
docker compose up --build -d
```

---

## Subsequent boots

The bootstrap sentinel `/var/www/MISP/.bootstrapped` prevents re-provisioning on container restart. The provisioner runs once (`restart: "no"`) and will not re-run unless the `keys` volume is removed.

If the container is **recreated** (e.g. after `docker compose up --build`), the sentinel is gone but the DB volume persists — the bootstrap detects the existing schema, skips the seed, and proceeds safely.

---

## Troubleshooting

**Build hangs during submodule fetch**
Normal — MISP has ~30 submodules fetched in parallel. The `--progress` flag shows per-submodule transfer stats. A cold build typically takes 10–20 minutes.

**MISP healthcheck keeps failing / container restart loop**
Check logs: `docker compose logs misp`. Common causes:
- DB not yet ready — `start_period` is 3 minutes; increase in `docker-compose.yml` for slow hardware.
- Bootstrap aborted — look for `[configure]` lines to see where it stopped.

**Provisioner exits with "Keys file already exists"**
Provisioning already ran successfully. To re-provision: `docker compose down -v && docker compose up -d`.

**Provisioner exits with "admin-authkey never appeared"**
The bootstrap did not complete in time. Check `docker compose logs misp` for errors in the `[configure]` phase. Usually a DB connectivity issue on first boot.

**User creation fails with "Password length requirement not met"**
MISP enforces a minimum 12-character password. Update `MISP_*_PASSWORD` in `.env` and do a full reset: `docker compose down -v && docker compose up -d`.

**php8.3-gnupg not available**
The Dockerfile falls back to `pecl install gnupg` automatically. If that also fails, pre-install `libgpgme-dev` in a custom base layer.
