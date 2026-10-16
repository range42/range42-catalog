# misp-star

A MISP element for the **MISP star** topology (one hub + N team spokes), copied from `misp-standalone` and carrying fixes that `misp-standalone` does not yet have. A single `docker compose up --build` brings up one self-provisioned MISP that can serve as the hub or as a team spoke. The hub/spoke pairing itself is done by the Ansible role `software.configure.misp_sync`, not by this element.

## Provenance and differences from `misp-standalone`

Copied from `misp-standalone` at catalog `dev` `2ec2e0f` (element last changed in `58d4e87`, #199). `misp-standalone` is left untouched.

This copy carries the five `misp-standalone` fixes reported as range42-catalog #219–#223, which are **not yet merged** into `misp-standalone`:

| Issue | Fix carried here |
|---|---|
| #219 | MISP background workers: supervisord `inet_http_server` on `127.0.0.1:9001` plus a `misp-workers` group (6 queues); a per-instance supervisor password generated in `entrypoint.sh` and stored in `SimpleBackgroundJobs.supervisor_*`. |
| #220 | Runtime image gains `ca-certificates`; the self-signed cert uses an `IP:` SAN when `MISP_HOSTNAME` is an IP address (strict v4/v6 check), a `DNS:` SAN otherwise. |
| #221 | `MISP.org` is set before `cake userInit`, so org 1 takes the configured name instead of `ORGNAME`. |
| #222 | `misp` healthcheck `start_period` raised from 180s to 900s (first boot under load exceeds 180s). |
| #223 | `entrypoint.sh` removes a stale `/run/apache2/apache2.pid` before supervisord starts. |

Image tags are renamed to `misp-star:${MISP_VERSION}` and `misp-star-modules:local` so the two elements do not collide on a shared Docker host.

Beyond the carried fixes, this element adds the star identity settings:

| Setting | Effect |
|---|---|
| `MISP_STAR_MODE` | `hub` (default): instructor org + one local org per team, as `misp-standalone`. `spoke`: org 1 is the team org; no instructor org, no extra team orgs. |
| `MISP_HOST_ORG_UUID` | Fixed UUID for the host organisation (org 1), applied right after `cake userInit`. |
| `MISP_ORG_UUID_NAMESPACE` | UUIDv5 namespace: every provisioned org (org 1 included, when `MISP_HOST_ORG_UUID` is blank) gets `uuid5(namespace, org name)`. Sync matches orgs by UUID — without a shared UUID the receiving MISP duplicates the org as `<name>_<random>`. |
| `MISP_DEFAULT_DISTRIBUTION` | Sets `MISP.default_event_distribution` (0–4). Attribute, object and event-report defaults are set to `event` (inherit) instead of `misp-standalone`'s `0` — MISP never pushes distribution 0, so pinning them would strip their data on push. Galaxy and analyst-data defaults stay `0` (they accept only 0–3 and do not gate event push). |
| `MISP_TEAM_USERS_CAN_PUBLISH` | `true` (default): team users are Publisher (role 4). `false`: User (role 3), which cannot publish. The team lead keeps Org Admin (role 2) either way. |

## Hub and spoke modes

- **Hub** (`MISP_STAR_MODE=hub`, default): behaves like `misp-standalone` — org 1 is `MISP_ORG`, the provisioner creates the instructor org and one local org per entry in `MISP_TEAMS`, plus their users.
- **Spoke** (`MISP_STAR_MODE=spoke`): set `MISP_ORG` to the team name. Org 1 **is** the team org; the team lead and team users are created in org 1. `MISP_TEAMS` is ignored and no instructor org exists. Team names must not contain spaces.

The hub/spoke pairing (sync users, server entries, sharing groups, certificate exchange) is done by the `software.configure.misp_sync` Ansible role, not by this element.

Sample events: the hub imports `provisioning/sample-events/*.json` as they are (org-only, local to the hub). A spoke imports a **team copy** of each fixture: every `uuid` in the event becomes `uuid5(<fixture uuid>, MISP_ORG)` and the event info gets a `[<team>]` prefix. Without this, the hub and every spoke hold events and attributes with the same UUIDs, and a pushed team event collides with the hub copy. The copies are created org-only and unpublished, because the team sharing group exists only after pairing. `software.configure.misp_sync` binds them to the team sharing group and publishes them.

Fixture format: each fixture must wrap the event in a top-level `Event` object with a `uuid` (`{"Event": {"uuid": ..., ...}}`), as MISP exports it. `software.configure.misp_sync` finds the team copies by `.Event.uuid`, so a bare event object would import but stay invisible to the role. The provisioner therefore refuses it and stops with `ERROR: <file>: no top-level "Event" object with a "uuid"`. Every attribute must also pass MISP validation (allowed category/type pair, valid value): `/events/add` still creates the event but drops an invalid attribute, and records `Attribute dropped due to validation` in the MISP audit log.

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
| Team lead | `<team>-lead@<domain>` | Org Admin | 2 |
| Team user | `<team>-user<i>@<domain>` | Publisher, or User when `MISP_TEAM_USERS_CAN_PUBLISH=false` | 4 / 3 |
| Instructor (hub only) | `instructor<i>@<domain>` | Org Admin | 2 |

Passwords are set via the corresponding `_PASSWORD` variables in `.env`.
**Passwords must be at least 12 characters** (MISP default policy enforced at user creation time).

---

## Configuration reference

| Variable | Description | Default |
|----------|-------------|---------|
| `MISP_VERSION` | MISP git tag to build from | `v2.5.50` |
| `MISP_HTTP_PORT` / `MISP_HTTPS_PORT` | Host ports for the MISP web UI | `80` / `443` |
| `MISP_HOSTNAME` | Host or IP in the TLS cert SAN (`IP:` SAN when it is an IP) | `localhost` |
| `MISP_BASEURL` | Sets `MISP.baseurl` **and** `MISP.external_baseurl` — must be the address the other star instances use, not `https://localhost` | `https://localhost` |
| `MISP_ORG` | Host organisation (org 1) name; in spoke mode, the team name | `Default Organisation` |
| `MISP_STAR_MODE` | `hub` or `spoke` — see "Hub and spoke modes" | `hub` |
| `MISP_HOST_ORG_UUID` | Fixed UUID for org 1 (blank: derive or keep random) | — |
| `MISP_ORG_UUID_NAMESPACE` | UUIDv5 namespace for deterministic org UUIDs | — |
| `MISP_DEFAULT_DISTRIBUTION` | Default event distribution (0–4); MISP never pushes `0` | `0` |
| `MISP_TEAM_USERS_CAN_PUBLISH` | `true`: team users get role 4 (Publisher); `false`: role 3 (User) | `true` |
| `MISP_TEAMS` | Comma-separated team names (one local org each; hub mode only) | `team-blue,team-red` |
| `MISP_INSTRUCTOR_ORG` / `MISP_INSTRUCTOR_COUNT` | Instructor org name / number of accounts (hub mode only) | `instructors` / `1` |
| `MISP_USERS_PER_TEAM` / `MISP_USER_DOMAIN` | Regular users per team / e-mail domain | `2` / `range42.local` |
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
  --build-arg MISP_VERSION=v2.5.50 \
  -t registry.example.com/range42/misp-star:v2.5.50 \
  -t registry.example.com/range42/misp-star:latest \
  .

# Push
docker push registry.example.com/range42/misp-star:v2.5.50
docker push registry.example.com/range42/misp-star:latest
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

## Instance health

After deploy, **Administration > Server Settings & Maintenance** (`/servers/serverSettings`) shows a red banner with exactly two CRITICAL entries. Both are deliberate for a lab without DNS and without SMTP:

| Setting | Diagnostic | Why it stays |
|---|---|---|
| `MISP.baseurl` | `Invalid baseurl, it has to be in the "https://FQDN" format.` | The element targets DNS-less deployments. The base URL is the instance IP, and the certificate carries an `IP:` SAN for it (#220). Sync uses this URL. |
| `MISP.disable_emailing` | `E-mailing is blocked.` | The element targets deployments without an SMTP server. The provisioner sets it to `true` on purpose. |

Any other CRITICAL entry is a real problem. The provisioner sets the two values that are CRITICAL only when they are unset:

- `Security.check_sec_fetch_site_header` = `true`. MISP refuses a POST, PUT or AJAX request whose `Sec-Fetch-Site` header is present and is not `same-origin`. Browsers send that header; the sync and API clients (curl) do not, so sync is not affected. It is `true` here because it blocks cross-site browser requests (CSRF) and the element serves one address only. Upstream warns that this check "can actively prevent the operation of instances hosted under multiple addresses" (`app/Model/Server.php` v2.5.50:2508). If the instance is later served under more than one address (a reverse proxy, an alternate hostname), set it to `false`: `docker compose exec misp runuser -u www-data -- /var/www/MISP/app/Console/cake Admin setSetting "Security.check_sec_fetch_site_header" false`.
- `Plugin.AI_services_enable` = `false`. No AI connector runs in this element.

Sample events: each instance stores every attribute of every fixture (spokes: of the team copies). Fixtures must use the `Event` wrapper (see [Fixture format](#hub-and-spoke-modes)); a missing wrapper stops the provisioner, and a lower stored count means MISP dropped an invalid attribute (search the audit log for `Attribute dropped due to validation`).

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
