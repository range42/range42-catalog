# Nextcloud — Standalone Docker Deployment

Issue: [#146](https://github.com/range42/range42-catalog/issues/146)

Standalone Nextcloud instance with automated user provisioning and app-password generation.
The initial admin is created automatically by Nextcloud on first boot; additional users and app
passwords are provisioned via the OCS API sidecar.

---

## Prerequisites

- Docker 24+ with Compose v2
- `make`

---

## Quick Start

```bash
cp .env.example .env          # edit secrets before deploying
make build-up                 # build provisioner image, start full stack
make logs-provisioner         # watch bootstrap output
make tokens                   # print generated app passwords
```

Nextcloud will be available at `http://localhost:8080` (or `HTTP_PORT`).
WebDAV: `http://localhost:8080/remote.php/dav/files/<USERNAME>/`

---

## Build & Push

```bash
# Build only the provisioner image
make build

# Full rebuild (no cache)
make rebuild

# Push to a registry (replace tag as needed)
docker tag nextcloud-provisioner registry.example.com/range42/nextcloud-provisioner:latest
docker push registry.example.com/range42/nextcloud-provisioner:latest
```

---

## Declaring Users

Users are declared entirely through environment variables in `.env` — no YAML file needed.

| Variable | Default | Description |
|----------|---------|-------------|
| `NC_TEAMS` | `team-blue,team-red` | Comma-separated list of team names |
| `NC_INSTRUCTOR_ORG` | `instructors` | Group label for instructor accounts |
| `NC_INSTRUCTOR_COUNT` | `1` | Number of instructor accounts |
| `NC_USERS_PER_TEAM` | `2` | Regular users per team (leads are additional) |
| `NC_USER_DOMAIN` | `range42.local` | Email domain for generated accounts |

For each team the provisioner creates one **lead** (admin group) and `NC_USERS_PER_TEAM` regular users.
Passwords are auto-generated on first run; they are written to `/tokens/nc-credentials.json`.

**The provisioner runs only once** (guarded by `/tokens/.provisioned`).
To re-provision with a clean volume, run:

```bash
make reprovision
```

---

## Credential Retrieval

```bash
# App passwords (username:apppassword, one per line)
make tokens

# Full credentials JSON (usernames + plain passwords + roles)
make keys
```

---

## WebDAV Usage

Mount a user's files via WebDAV using the generated app password:

```
davs://localhost:8080/remote.php/dav/files/<USERNAME>/
```

Example with `curl`:

```bash
curl -u trainee01:<app-password> \
  https://localhost:8080/remote.php/dav/files/trainee01/
```

---

## API Usage Examples

```bash
# List files (WebDAV PROPFIND)
curl -X PROPFIND \
  -u trainee01:<app-password> \
  http://localhost:8080/remote.php/dav/files/trainee01/

# Upload a file
curl -T local_file.txt \
  -u trainee01:<app-password> \
  http://localhost:8080/remote.php/dav/files/trainee01/remote_file.txt

# OCS user list (admin only)
curl -H "OCS-APIRequest: true" -H "Accept: application/json" \
  -u nc-admin:Admin1234! \
  http://localhost:8080/ocs/v1.php/cloud/users
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NC_DOMAIN` | `localhost` | Trusted domain for Nextcloud |
| `NC_ADMIN_USER` | `nc-admin` | Initial admin username (auto-created by Nextcloud) |
| `NC_ADMIN_PASS` | `Admin1234!` | Initial admin password |
| `NC_TEAMS` | `team-blue,team-red` | Comma-separated team list |
| `NC_INSTRUCTOR_ORG` | `instructors` | Group label for instructor accounts |
| `NC_INSTRUCTOR_COUNT` | `1` | Number of instructor accounts |
| `NC_USERS_PER_TEAM` | `2` | Regular users per team |
| `NC_USER_DOMAIN` | `range42.local` | Email domain for generated accounts |
| `POSTGRES_USER` | `nextcloud` | DB user |
| `POSTGRES_PASSWORD` | `nextcloud` | DB password — **change before deploying** |
| `POSTGRES_DB` | `nextcloud` | DB name |
| `HTTP_PORT` | `8080` | Host port for HTTP |

---

## Troubleshooting

**Provisioner exits immediately with "Already provisioned"**
Remove the tokens volume and re-run: `make reprovision`

**Provisioner fails with "Nextcloud did not become healthy after 180 s"**
Nextcloud first-boot can take several minutes. Increase `start_period` in `compose.yml`
or check `docker logs nextcloud` for errors.

**User creation returns a 403 or 401**
Verify `NC_ADMIN_USER` and `NC_ADMIN_PASS` in `.env` match the actual admin credentials.

**App password generation fails (ERROR in tokens.txt)**
The OCS v2 endpoint requires the user to exist and be enabled.
Check `make logs-provisioner` for the exact error.

**Port 8080 already in use**
Set `HTTP_PORT=8081` (or any free port) in `.env`.
