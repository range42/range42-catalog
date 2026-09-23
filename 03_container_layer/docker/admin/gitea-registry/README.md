# gitea-registry

Standalone [Gitea](https://gitea.io) instance configured as an OCI Docker registry, with automated user provisioning and personal access token generation.

**Role (issue #172):** this element is **not student-facing**. It is the internal Docker image cache for the lab infrastructure: the operator builds all `admin/*` images locally, pushes them here once (`make push-images`), and lab VMs pull from this registry instead of docker.io — so labs run **offline** after a first online warm-up.

Gitea's built-in [Packages / Container Registry](https://docs.gitea.io/en-us/packages/container/) feature is enabled via `GITEA__packages__ENABLED=true`. Each provisioned user receives a `registry-token` personal access token that can be used directly with `docker login`.

---

## Quick Start

```bash
# 1. Copy and fill in secrets
cp .env.example .env
# Edit .env — replace all CHANGEME_ values

# 2. Declare users / orgs in provisioning/users.yml

# 3. Build and start
make build-up

# 4. Retrieve generated tokens
make tokens

# 5. Warm up the cache: build + push every admin/* image set
make push-images
```

---

## Makefile targets

| Target | Description |
|---|---|
| `make up` | Start full stack in background |
| `make down` | Stop and remove all containers |
| `make build` | Build provisioner image |
| `make build-up` | Build then start |
| `make rebuild-up` | Full rebuild without cache then start |
| `make reprovision` | Remove stamp and re-run provisioner |
| `make logs-provisioner` | Tail provisioner logs |
| `make tokens` | Print generated registry tokens |
| `make push-images` | Build + push every `admin/*` stack image to this registry |
| `make backup` | Archive data volume + Postgres dump into `./backup/` |
| `make sbom` | CycloneDX SBOM per pushed image (trivy, operator-side) |
| `make scan` | Trivy vulnerability scan of pushed images (operator-side) |
| `make term` | Shell into gitea-registry container |
| `make clean` | Destroy all containers, images, volumes |

---

## Auth scheme — push vs pull (issue #172)

Two credential classes, enforced by token scope:

| Class | users.yml | Token scopes | Used by |
|---|---|---|---|
| **Push** (operator) | `admins:` entries, or `users:` with `registry_role: push` | `read:package`, `write:package` | Operator build box, `make push-images` |
| **Pull** (lab VM) | `users:` entries (default `registry_role: pull`) | `read:package` | Lab VMs, catalog-try clients |

`make tokens` output format: `username:token:scopes`.

```yaml
admins:
  - username: gitea-admin        # operator — push token
    ...
users:
  - username: lab-pull           # lab VMs — read-only token
    registry_role: pull
  - username: operator01         # extra push credential (CI / build box)
    registry_role: push
```

---

## Namespaces (issue #172)

Orgs declared under `orgs:` in `users.yml` are created at first boot:

- `range42-admin` — pre-warmed `admin/*` image set (default target of `make push-images`)
- `team-blue`, `team-red` — per-team namespaces: `DOMAIN:PORT/team-blue/<image>:<tag>`

---

## Operator push workflow + offline guarantee (issue #172)

```bash
# one command: builds every ../<stack>/compose.yml and pushes ALL images
# (locally built + upstream base images) to DOMAIN:PORT/range42-admin/
make push-images

# subset / custom namespace:
REGISTRY_OWNER=team-blue ./scripts/push-images.sh rocketchat gitea
```

After the warm-up, a fresh lab VM with **no internet** can start any `admin/*` stack by pulling from this registry only. Point the VM's Docker at the cache with the read-only credential (`lab-pull` token) and, for the self-signed cert:

```bash
sudo mkdir -p /etc/docker/certs.d/<host:port>
sudo cp registry-cert.pem /etc/docker/certs.d/<host:port>/ca.crt   # exported by `make tokens` volume
docker login <host:port> -u lab-pull -p <token>
```

---

## TLS

`GITEA_TLS_MODE` in `.env`:

- `disabled` — plain HTTP
- `self-signed` — cert auto-generated at first boot (SAN = `GITEA_DOMAIN`, works for IPs)
- `provided` — **operator-provided signed cert**: drop `server.crt` + `server.key` into `./certs/` next to `compose.yml`; the cert-gen init container imports them with correct ownership at start

---

## Pull-through cache (issue #172)

Gitea CE cannot act as a pull-through proxy for container images ([go-gitea/gitea#26756](https://github.com/go-gitea/gitea/issues/26756)). Hybrid online/offline fallback is provided by an **optional `registry:2` mirror** sidecar:

```bash
docker compose --profile proxy-cache up -d      # mirror on :5001
```

On lab VMs: `/etc/docker/daemon.json` → `{"registry-mirrors": ["http://<vm-ip>:5001"]}`. Docker uses the mirror's cache when offline-cached, and falls through to docker.io when the mirror misses and upstream is reachable.

---

## Quotas, GC, retention, audit (issue #172)

All tunable in `.env`:

| Concern | Mechanism | Keys |
|---|---|---|
| Per-image quota | Gitea packages limits | `GITEA_PKG_LIMIT_SIZE_CONTAINER`, `GITEA_PKG_LIMIT_TOTAL_OWNER_SIZE` |
| Garbage collection | `[cron.cleanup_packages]` (weekly) | `GITEA_PKG_GC_SCHEDULE`, `GITEA_PKG_GC_OLDER_THAN` |
| Per-image retention | Cleanup rule per owner/org (keep last N container versions, purge older than D days) — applied by the provisioner via the web UI form (no REST API in Gitea 1.27) | `GITEA_PKG_KEEP_COUNT`, `GITEA_PKG_REMOVE_DAYS` |
| Audit trail | Gitea access log (every push/pull HTTP request) → container stdout; retention via docker json-file rotation. Note: Gitea CE has no first-class audit-log UI (Enterprise feature) | `GITEA_LOG_MAX_SIZE`, `GITEA_LOG_MAX_FILES`, `GITEA_NOTICE_RETENTION` |

```bash
# inspect push/pull audit trail
docker logs gitea-registry 2>&1 | grep -E 'PUT|GET /v2/'
```

---

## Webhook on push (issue #172)

A system-wide webhook (Slack payload) fires on every package event. Set `GITEA_WEBHOOK_URL` (+ optional `GITEA_WEBHOOK_CHANNEL`) in `.env` before first boot, or let the `admin_services_lab` scenario wire it to Rocket.Chat automatically in stage_02. Rocket.Chat's incoming webhook must have `overrideDestinationChannelEnabled: true` (the provisioned one does).

---

## Backup (issue #172)

```bash
make backup     # → ./backup/gitea-registry-data-<stamp>.tar.gz  (blobs)
                #   ./backup/gitea-registry-db-<stamp>.sql.gz    (metadata)
```

Restore = recreate the stack, untar into the data volume, `psql < dump` into the db.

---

## SBOM + vulnerability scanning (issue #172)

Scan-on-push is **not implementable on this stack**: Gitea CE has no scanning hook and the lab VM must work offline (trivy needs internet or a pre-synced vulnerability DB). Operator-side equivalent, run where internet exists:

```bash
make sbom     # CycloneDX SBOM per image → ./sbom/ + attached as generic package sbom-<image>/<tag>
make scan     # HIGH/CRITICAL trivy report per image
```

---

## Declaring Users

Edit `provisioning/users.yml` before the first `make up` (see the auth-scheme section above for `registry_role` and `orgs`).

The provisioner is **idempotent** — running it again on an already-provisioned stack exits immediately (stamp at `/data/gitea/.provisioned`).

To re-provision: `make reprovision`

---

## SSH Key Format

SSH keys must be valid OpenSSH public keys. Supported types:

- `ssh-ed25519 AAAA...`
- `ssh-rsa AAAA...`
- `ecdsa-sha2-nistp256 AAAA...`

Set `ssh_keys: []` for users who do not need SSH access.

---

## Docker Registry Usage

Gitea acts as an OCI-compatible registry at `DOMAIN:PORT`.

### Login

```bash
# Using a personal access token (recommended)
docker login localhost:3001 -u lab-pull -p TOKEN
```

### Push an image (push credential required)

```bash
docker tag myimage:latest localhost:3001/team-blue/myimage:latest
docker push localhost:3001/team-blue/myimage:latest
```

### Pull an image

```bash
docker pull localhost:3001/range42-admin/myimage:latest
```

### List packages via API

```bash
curl -sk https://localhost:3001/api/v1/packages/range42-admin \
  -u lab-pull:TOKEN | jq .
```

---

## Token Retrieval

Personal access tokens (`registry-token`) are generated for every user during provisioning and written to a named volume.

```bash
make tokens
```

Token file format:
```
# Generated by gitea-registry provisioner
# Format: username:token:scopes
# docker login usage: docker login DOMAIN:PORT -u USERNAME -p TOKEN
gitea-admin:abc123...sha1:read:package,write:package
lab-pull:def456...sha1:read:package
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `GITEA_DOMAIN` | `localhost` | Domain for Gitea server and SSH |
| `GITEA_BASE_URL` | `http://localhost:3000` | Full root URL |
| `GITEA_TLS_MODE` | `disabled` | `disabled` \| `self-signed` \| `provided` (see TLS) |
| `GITEA_SECRET_KEY` | `please-change-me-in-production` | App secret key (`openssl rand -hex 32`) |
| `GITEA_INTERNAL_TOKEN` | `please-change-me-in-production` | Internal token (`gitea generate secret INTERNAL_TOKEN`) |
| `GITEA_ADMIN_USER` | `gitea-admin` | Admin username (must match `admins[0]` in users.yml) |
| `GITEA_ADMIN_PASS` | `Admin1234!` | Admin password |
| `GITEA_WEBHOOK_URL` | *(empty)* | Chat incoming-webhook notified on package events |
| `GITEA_WEBHOOK_CHANNEL` | `#general` | Channel for the package webhook |
| `GITEA_PKG_LIMIT_SIZE_CONTAINER` | `-1` | Max size per container upload (`5 GiB` style; -1 = unlimited) |
| `GITEA_PKG_LIMIT_TOTAL_OWNER_SIZE` | `-1` | Max total package size per owner |
| `GITEA_PKG_GC_SCHEDULE` | `@weekly` | cleanup_packages cron schedule |
| `GITEA_PKG_GC_OLDER_THAN` | `24h` | Age before unreferenced blob data is collected |
| `GITEA_PKG_KEEP_COUNT` | `10` | Retention: container versions kept per package (1/5/10/25/50/100) |
| `GITEA_PKG_REMOVE_DAYS` | `30` | Retention: purge versions older than (7/14/30/60/90/180) |
| `GITEA_LOG_MAX_SIZE` / `GITEA_LOG_MAX_FILES` | `20m` / `7` | Access-log (audit) rotation |
| `GITEA_NOTICE_RETENTION` | `2160h` | System-notice purge age |
| `PROXY_CACHE_PORT` / `PROXY_CACHE_REMOTE` | `5001` / docker.io | Optional pull-through mirror (profile `proxy-cache`) |
| `POSTGRES_USER` | `gitea` | Database user |
| `POSTGRES_PASSWORD` | `gitea` | Database password |
| `POSTGRES_DB` | `gitea` | Database name |
| `HTTP_PORT` | `3000` | Host port mapped to Gitea HTTP |
| `SSH_PORT` | `2222` | Host port mapped to Gitea SSH |

---

## Troubleshooting

**Provisioner exits before Gitea is ready**

The provisioner retries for up to 180 s. If Gitea takes longer (cold pull), increase `start_period` in `compose.yml` or run `make reprovision` after Gitea is healthy.

**Token shows `ERROR`**

The Gitea API returned an empty response. Check provisioner logs:

```bash
make logs-provisioner
```

Common causes: Gitea not yet fully initialized, or the user creation step failed silently. Run `make reprovision` after verifying Gitea is up.

**`docker login` fails with 401**

Ensure the Packages feature is enabled. Check the Gitea admin panel at `http://localhost:3000/-/admin/self` or verify `GITEA__packages__ENABLED=true` is set in `compose.yml`.

**`docker push` fails with `x509: certificate signed by unknown authority`**

Trust the registry cert on the client: copy `registry-cert.pem` (exported next to the tokens) to `/etc/docker/certs.d/<host:port>/ca.crt`.

**Port conflict**

Change `HTTP_PORT` or `SSH_PORT` in `.env` and run `make down && make up`.
