# Rocket.Chat — Standalone Docker Deployment

Issue 147. Dockerized Rocket.Chat with MongoDB replica set and team-aware automated user and Personal Access Token provisioning.

---

## Prerequisites

| Requirement | Version |
|---|---|
| Docker | 24+ |
| Docker Compose (plugin) | v2.20+ |
| `make` | any |

---

## Quick Start

```sh
# 1. Copy and edit environment file
cp .env.example .env
$EDITOR .env

# 2. Build and start the full stack
make build-up

# 3. Wait for the provisioner to finish (~2 min on first boot), then check tokens
make tokens   # username:PAT pairs
make keys     # full credentials JSON
```

> **MongoDB replica set** initialises automatically via the `mongo-init-replica` one-shot container. No manual `rs.initiate()` step is needed.

The web UI is available at `http://localhost:3000` (or `RC_BASE_URL`).
Default admin credentials: `rc-admin` / `Admin1234!` (change in `.env`).

---

## Provisioning Architecture

User provisioning is handled by a dedicated one-shot `provisioner` service (Alpine + bash/curl/jq/openssl). Scripts are **volume-mounted at runtime** — not baked into the image — so they can be updated without a rebuild.

```
provision.sh          ← orchestrator, mounted as ENTRYPOINT
  └─ provision-users.sh    creates all user accounts, writes /tokens/rc-credentials.json
  └─ provision-tokens.sh   generates PATs for every user, writes /tokens/tokens.txt
```

Provisioning is **idempotent**: a `/tokens/.provisioned` stamp prevents re-running on container restart. To re-provision, run `make reprovision`.

### What gets created

Given the default `.env.example` values (`RC_TEAMS=team-blue,team-red`, `RC_INSTRUCTOR_COUNT=1`, `RC_USERS_PER_TEAM=2`):

| Username | Role | Team |
|---|---|---|
| `rc-admin` | admin | admin |
| `instructors` | admin | instructors |
| `team-blue-lead` | admin | team-blue |
| `team-blue-user1` | user | team-blue |
| `team-blue-user2` | user | team-blue |
| `team-red-lead` | admin | team-red |
| `team-red-user1` | user | team-red |
| `team-red-user2` | user | team-red |

All passwords are auto-generated (20-char, `R42!` prefix + `openssl rand`). Retrieve them via `make keys`.

---

## Token Retrieval

Two output files are written to the `rocketchat-tokens` named volume:

```sh
# Personal Access Tokens (username:PAT, one per line)
make tokens

# Full credentials JSON (usernames, passwords, roles, teams)
make keys
```

`tokens.txt` format:
```
rc-admin:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
team-blue-lead:yyyyyyyyyyyyyyyyyyyyyyyyyyyy
```

`rc-credentials.json` format:
```json
{
  "service": "rocketchat",
  "baseurl": "http://localhost:3000",
  "users": [
    {"username": "rc-admin",       "role": "admin", "team": "admin",       "password": "Admin1234!"},
    {"username": "team-blue-lead", "role": "admin", "team": "team-blue",   "password": "R42!..."},
    {"username": "team-blue-user1","role": "user",  "team": "team-blue",   "password": "R42!..."}
  ]
}
```

Both files are `chmod 600` inside the volume.

---

## Build & Push

```sh
make build          # build provisioner image
make rebuild        # full rebuild without cache

# Tag and push (adjust registry as needed)
docker tag rocketchat-provisioner registry.example.com/range42/rocketchat-provisioner:latest
docker push registry.example.com/range42/rocketchat-provisioner:latest
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `RC_HTTP_PORT` | `3000` | Host port mapped to Rocket.Chat |
| `RC_HOSTNAME` | `localhost` | Hostname for URL construction |
| `RC_BASE_URL` | `http://localhost:3000` | Public URL (`ROOT_URL` in Rocket.Chat) |
| `RC_ADMIN_USER` | `rc-admin` | Bootstrap admin username |
| `RC_ADMIN_PASS` | `Admin1234!` | Bootstrap admin password |
| `RC_ADMIN_EMAIL` | `admin@range42.local` | Bootstrap admin email |
| `RC_TEAMS` | `team-blue,team-red` | Comma-separated team names |
| `RC_INSTRUCTOR_ORG` | `instructors` | Username prefix for instructor accounts |
| `RC_INSTRUCTOR_COUNT` | `1` | Number of instructor accounts to create |
| `RC_USERS_PER_TEAM` | `2` | Regular (non-lead) users per team |
| `RC_USER_DOMAIN` | `range42.local` | Email domain for generated accounts |

---

## API Usage Examples

```sh
# Get server info (no auth needed)
curl http://localhost:3000/api/v1/info

# Authenticate and store credentials
LOGIN=$(curl -sf -X POST http://localhost:3000/api/v1/login \
  -H "Content-Type: application/json" \
  -d '{"username":"rc-admin","password":"Admin1234!"}')
USER_ID=$(echo "${LOGIN}" | jq -r '.data.userId')
AUTH_TOKEN=$(echo "${LOGIN}" | jq -r '.data.authToken')

# List channels
curl http://localhost:3000/api/v1/channels.list \
  -H "X-Auth-Token: ${AUTH_TOKEN}" \
  -H "X-User-Id: ${USER_ID}"

# Post a message
curl -X POST http://localhost:3000/api/v1/chat.postMessage \
  -H "X-Auth-Token: ${AUTH_TOKEN}" \
  -H "X-User-Id: ${USER_ID}" \
  -H "Content-Type: application/json" \
  -d '{"channel":"#general","text":"Hello from range42!"}'
```

---

## Troubleshooting

### MongoDB replica set issues

**Symptom:** Rocket.Chat exits with `MongoServerError: not primary`.

**Fix:**
```sh
docker logs rocketchat-mongo-init

# Force re-init manually if needed
docker exec rocketchat-mongodb mongosh --eval \
  "rs.initiate({ _id: 'rs0', members: [{ _id: 0, host: 'mongodb:27017' }] })"
```

### Provisioner exits with auth error

**Symptom:** `[provision-users] ERROR: Failed to authenticate as rc-admin.`

**Cause:** Rocket.Chat is not yet fully ready (can take 60–90 s on first boot). The provisioner waits up to 180 s then exits with an error.

**Fix:** Re-run the provisioner:
```sh
make reprovision
```

### Re-provisioning

Remove the idempotency stamp and re-run:
```sh
make reprovision
```

To completely reset users and tokens (start fresh):
```sh
docker compose down -v
make build-up
```
