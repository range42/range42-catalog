# Rocket.Chat — Standalone Docker Deployment

Issue 147. Dockerized Rocket.Chat with MongoDB replica set and automated user / personal-access-token provisioning.

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

# 3. Wait for the provisioner to finish, then check tokens
make tokens
```

> **MongoDB replica set** initialises automatically via the `mongo-init-replica` one-shot container. No manual `rs.initiate()` step is needed.

The web UI is available at `http://localhost:3000` (or `RC_BASE_URL`).
Default admin credentials: `rc-admin` / `Admin1234!` (change in `.env`).

---

## Build & Push

```sh
# Build provisioner image
make build

# Full rebuild without cache
make rebuild

# Tag and push (adjust registry as needed)
docker tag rocketchat-provisioner registry.example.com/range42/rocketchat-provisioner:latest
docker push registry.example.com/range42/rocketchat-provisioner:latest
```

---

## Declaring Users

Edit `provisioning/users.yml` before first deployment:

```yaml
# !! CHANGE ALL PASSWORDS BEFORE DEPLOYING !!

admins:
  - username: rc-admin2
    email: admin2@range42.local
    password: "Admin1234!"
    name: "RC Admin 2"

users:
  - username: trainee01
    email: trainee01@range42.local
    password: "Trainee1234!"
    name: "Trainee 01"
```

The primary admin (`rc-admin`) is created automatically via the `ADMIN_USERNAME` environment variable. The users listed in `users.yml` are **additional** accounts.

---

## Token Retrieval

Personal access tokens are written to `/tokens/tokens.txt` (inside the `rocketchat-tokens` volume) at the end of provisioning.

```sh
# Print all tokens
make tokens

# Or read directly from the volume
docker run --rm -v rocketchat_rocketchat-tokens:/tokens:ro busybox cat /tokens/tokens.txt
```

Each line has the format:

```
username:personalAccessToken
```

---

## API Usage Examples

```sh
# Get server info (no auth needed)
curl http://localhost:3000/api/v1/info

# List channels (authenticated)
TOKEN="<paste token from tokens.txt>"
USER_ID="<userId — retrieve via login endpoint>"

curl -X GET http://localhost:3000/api/v1/channels.list \
  -H "X-Auth-Token: ${TOKEN}" \
  -H "X-User-Id: ${USER_ID}"

# Post a message
curl -X POST http://localhost:3000/api/v1/chat.postMessage \
  -H "X-Auth-Token: ${TOKEN}" \
  -H "X-User-Id: ${USER_ID}" \
  -H "Content-Type: application/json" \
  -d '{"channel":"#general","text":"Hello from range42!"}'
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `RC_BASE_URL` | `http://localhost:3000` | Public URL (used by Rocket.Chat as `ROOT_URL`) |
| `RC_ADMIN_USER` | `rc-admin` | Initial admin username |
| `RC_ADMIN_PASS` | `Admin1234!` | Initial admin password |
| `RC_ADMIN_EMAIL` | `admin@range42.local` | Initial admin email |
| `HTTP_PORT` | `3000` | Host port mapped to Rocket.Chat |

---

## Troubleshooting

### MongoDB replica set issues

**Symptom:** Rocket.Chat exits with `MongoServerError: not primary`.

**Cause:** The replica set has not been initialised yet. The `mongo-init-replica` container handles this automatically, but it requires MongoDB to be healthy first.

**Fix:**
```sh
# Check mongo-init-replica logs
docker logs rocketchat-mongo-init

# Force re-init manually if needed
docker exec rocketchat-mongodb mongosh --eval \
  "rs.initiate({ _id: 'rs0', members: [{ _id: 0, host: 'mongodb:27017' }] })"
```

### Provisioner exits with auth error

**Symptom:** `[init] ERROR: Failed to authenticate as admin.`

**Cause:** Rocket.Chat is not yet fully ready (it can take 60–90 s on first boot).

**Fix:** The provisioner will be restarted automatically by Docker Compose if `restart: "no"` is overridden, or you can re-run it manually:
```sh
docker compose run --rm provisioner
```

### Tokens already exist

If the provisioner runs a second time, `generatePersonalAccessToken` will fail for tokens named `api-token` that already exist. This is handled gracefully — a warning is printed and the existing token is left in place. Re-provision with a clean volume to regenerate:
```sh
docker volume rm rocketchat_rocketchat-tokens
docker compose run --rm provisioner
```
