# Gitea — Standalone Docker Deployment

Issue: [#141](https://github.com/range42/range42-catalog/issues/141)

Standalone Gitea instance with automated user provisioning and API token generation.
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
make tokens                   # print generated API tokens
```

Gitea will be available at `http://localhost:3000` (or `GITEA_BASE_URL`).
SSH cloning: `git clone git@localhost:2222/<org>/<repo>.git`

---

## Build & Push

```bash
# Build only the provisioner image
make build

# Full rebuild (no cache)
make rebuild

# Push to a registry (replace tag as needed)
docker tag gitea-provisioner registry.example.com/range42/gitea-provisioner:latest
docker push registry.example.com/range42/gitea-provisioner:latest
```

---

## Declaring Users

Users are declared entirely through environment variables in `.env` — no YAML file needed.

| Variable | Default | Description |
|----------|---------|-------------|
| `GITEA_TEAMS` | `team-blue,team-red` | Comma-separated list of team names |
| `GITEA_INSTRUCTOR_COUNT` | `1` | Number of instructor accounts |
| `GITEA_USERS_PER_TEAM` | `2` | Regular users per team (leads are additional) |
| `GITEA_USER_DOMAIN` | `range42.local` | Email domain for generated accounts |

For each team the provisioner creates one **lead** and `GITEA_USERS_PER_TEAM` regular users.
The initial admin (`GITEA_ADMIN_USER`) is created via the Gitea CLI on first boot.
Passwords are auto-generated on first run; they are written to `/tokens/gitea-credentials.json`.

**The provisioner runs only once** (guarded by `/tokens/.provisioned`).
To re-provision with a clean volume, run:

```bash
make reprovision
```

---

## Credential Retrieval

```bash
# API tokens (username:token, one per line)
make tokens

# Full credentials JSON (usernames + passwords + roles)
make keys
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GITEA_DOMAIN` | `localhost` | Public hostname |
| `GITEA_BASE_URL` | `http://localhost:3000` | Root URL shown in clone URLs |
| `GITEA_SECRET_KEY` | *(required)* | App secret — `openssl rand -hex 32` |
| `GITEA_INTERNAL_TOKEN` | *(required)* | Internal token — `gitea generate secret INTERNAL_TOKEN` |
| `GITEA_ADMIN_USER` | `gitea-admin` | Initial admin username |
| `GITEA_ADMIN_PASS` | `Admin1234!` | Initial admin password — **change before deploying** |
| `GITEA_TEAMS` | `team-blue,team-red` | Comma-separated team list |
| `GITEA_INSTRUCTOR_COUNT` | `1` | Number of instructor accounts |
| `GITEA_USERS_PER_TEAM` | `2` | Regular users per team |
| `GITEA_USER_DOMAIN` | `range42.local` | Email domain for generated accounts |
| `POSTGRES_USER` | `gitea` | DB user |
| `POSTGRES_PASSWORD` | *(required)* | DB password — **change before deploying** |
| `POSTGRES_DB` | `gitea` | DB name |
| `HTTP_PORT` | `3000` | Host port for HTTP |
| `SSH_PORT` | `2222` | Host port for SSH (avoids conflict with host sshd) |

---

## Troubleshooting

**Provisioner exits immediately with "Already provisioned"**
Remove the stamp and re-run: `make reprovision`

**`gitea admin user create` fails**
Check provisioner logs: `make logs-provisioner`
The stamp is NOT written on failure — restart the provisioner to retry.

**Token creation returns empty**
Ensure the user was created successfully. Check `make logs-provisioner` for errors.

**Port 3000 already in use**
Set `HTTP_PORT=3001` (or any free port) in `.env`.
