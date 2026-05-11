# Mattermost — Standalone Docker Deployment

Issue: [#143](https://github.com/range42/range42-catalog/issues/143)

Standalone Mattermost Team Edition instance with automated user provisioning
and personal access token generation.
All accounts are declared in `provisioning/users.yml`; registration is disabled
via environment variables by default.

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
```

Mattermost will be available at `http://localhost:8065` (or `MM_BASE_URL`).

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

Edit `provisioning/users.yml` before the first `make up`:

```yaml
admins:
  - username: mm-admin
    email: admin@range42.local
    password: "Admin1234!"

users:
  - username: trainee01
    email: trainee01@range42.local
    password: "Trainee1234!"
```

- Add/remove entries to change the provisioned user set.
- `admins[]` entries receive Mattermost system-admin privileges.
- `users[]` entries are regular accounts.

**The provisioner runs only once** (guarded by `/tokens/.provisioned`).
To re-provision after changes, run:

```bash
make reprovision
```

---

## Token Retrieval

Personal access tokens are generated for every user at provisioning time
and written to `/tokens/tokens.txt` (one `username:token` per line).

```bash
# Via make target
make tokens

# Via docker exec
docker exec mattermost-provisioner cat /tokens/tokens.txt
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
| `MM_ADMIN_USER` | `mm-admin` | Must match `admins[0].username` in `users.yml` |
| `MM_ADMIN_PASS` | `Admin1234!` | Must match `admins[0].password` in `users.yml` |
| `MM_TEAM_NAME` | `range42` | Default team created by provisioner |
| `POSTGRES_USER` | `mattermost` | DB user |
| `POSTGRES_PASSWORD` | *(required)* | DB password |
| `POSTGRES_DB` | `mattermost` | DB name |
| `HTTP_PORT` | `8065` | Host port for Mattermost HTTP |

---

## Troubleshooting

**Provisioner exits immediately with "Already provisioned"**
Remove the stamp and re-run: `make reprovision`

**`mattermost user create` fails silently**
Check provisioner logs: `make logs-provisioner`
The stamp is NOT written on failure — restart the provisioner to retry.

**Token creation returns empty**
Ensure `MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=true` is set (already the
default in `compose.yml`). Verify with:
```bash
curl http://localhost:8065/api/v4/config/client?format=old | jq '.EnableUserAccessTokens'
```

**Port 8065 already in use**
Set `HTTP_PORT=8066` (or any free port) in `.env`.

**Mattermost fails to start / DB connection refused**
Check that the `db` service passed its healthcheck before `mattermost` started:
```bash
docker compose logs db
```
