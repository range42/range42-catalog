# Mattermost — Standalone Docker Deployment

Issue: [#143](https://github.com/range42/range42-catalog/issues/143)

Standalone Mattermost Team Edition instance with automated user provisioning
and personal access token generation.
Users are declared entirely through environment variables — no YAML file needed.

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
make tokens                   # print generated personal access tokens
```

Mattermost will be available at `http://localhost:8065` (or `HTTP_PORT`).

---

## Build & Push

```bash
# Build only the provisioner image
make build

# Full rebuild (no cache)
make rebuild

# Push to a registry (replace tag as needed)
docker tag mattermost-provisioner registry.example.com/range42/mattermost-provisioner:latest
docker push registry.example.com/range42/mattermost-provisioner:latest
```

---

## Declaring Users

Users are declared entirely through environment variables in `.env` — no YAML file needed.

| Variable | Default | Description |
|----------|---------|-------------|
| `MM_TEAMS` | `team-blue,team-red` | Comma-separated list of team names |
| `MM_INSTRUCTOR_ORG` | `instructors` | Group label for instructor accounts |
| `MM_INSTRUCTOR_COUNT` | `1` | Number of instructor accounts |
| `MM_USERS_PER_TEAM` | `2` | Regular users per team (leads are additional) |
| `MM_USER_DOMAIN` | `range42.local` | Email domain for generated accounts |

For each team the provisioner creates one **lead** and `MM_USERS_PER_TEAM` regular users.
The initial admin (`MM_ADMIN_USER`) is created first and automatically receives
`system_admin` privileges (Mattermost promotes the first user on a fresh database).
Passwords are auto-generated on first run; they are written to `/tokens/mm-credentials.json`.

**The provisioner runs only once** (guarded by `/tokens/.provisioned`).
To re-provision with a clean volume, run:

```bash
make reprovision
```

---

## Credential Retrieval

```bash
# Personal access tokens (username:token, one per line)
make tokens

# Full credentials JSON (usernames + passwords + roles)
make keys
```

---

## API Usage Examples

```bash
# Replace <token> with a value from tokens.txt

# Get current user info
curl -H "Authorization: Bearer <token>" http://localhost:8065/api/v4/users/me

# List channels in the default team
curl -H "Authorization: Bearer <token>" \
  "http://localhost:8065/api/v4/users/me/teams/channels"

# Post a message to a channel
curl -X POST http://localhost:8065/api/v4/posts \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"channel_id":"<channel_id>","message":"Hello from the API"}'
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MM_BASE_URL` | `http://localhost:8065` | Public URL of the Mattermost instance |
| `MM_ADMIN_USER` | `admin` | Initial admin username |
| `MM_ADMIN_PASS` | `Admin1234!` | Initial admin password — **change before deploying** |
| `MM_TEAM_NAME` | `range42` | Default team created by provisioner |
| `MM_TEAMS` | `team-blue,team-red` | Comma-separated team list |
| `MM_INSTRUCTOR_ORG` | `instructors` | Group label for instructor accounts |
| `MM_INSTRUCTOR_COUNT` | `1` | Number of instructor accounts |
| `MM_USERS_PER_TEAM` | `2` | Regular users per team |
| `MM_USER_DOMAIN` | `range42.local` | Email domain for generated accounts |
| `POSTGRES_USER` | `mattermost` | DB user |
| `POSTGRES_PASSWORD` | *(required)* | DB password — **change before deploying** |
| `POSTGRES_DB` | `mattermost` | DB name |
| `HTTP_PORT` | `8065` | Host port for Mattermost HTTP |

---

## Troubleshooting

**Provisioner exits immediately with "Already provisioned"**
Remove the stamp and re-run: `make reprovision`

**Provisioner fails with "Mattermost did not become healthy after 180 s"**
Mattermost first-boot can take several minutes. Check `docker logs mattermost` for errors.

**Admin creation fails (first user not promoted to system_admin)**
Ensure `MM_SERVICESETTINGS_ENABLEAPICREATEACCOUNT=true` and
`MM_TEAMSETTINGS_ENABLEOPENSERVER=true` are set (already the default in `compose.yml`).

**Token creation returns empty**
Ensure `MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=true` is set (already the default in `compose.yml`).

**Port 8065 already in use**
Set `HTTP_PORT=8066` (or any free port) in `.env`.

**Mattermost fails to start / DB connection refused**
Check that the `db` service passed its healthcheck: `docker compose logs db`
