# Gitea — Standalone Docker Deployment

Issue: [#141](https://github.com/range42/range42-catalog/issues/141)

Standalone Gitea instance with automated user and SSH-key provisioning.
Registration is disabled by default; all accounts are declared in `provisioning/users.yml`.

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

## Declaring Users and SSH Keys

Edit `provisioning/users.yml` before the first `make up`:

```yaml
admins:
  - username: gitea-admin
    email: admin@range42.local
    password: "Admin1234!"
    ssh_keys:
      - "ssh-ed25519 AAAA... user@host"   # full public key string

users:
  - username: trainee01
    email: trainee01@range42.local
    password: "Trainee1234!"
    ssh_keys: []   # no SSH key for this user
```

- Add/remove entries to change the provisioned user set.
- `admins[]` entries receive Gitea admin privileges.
- `users[]` entries are regular accounts.
- `ssh_keys` is a list of raw public-key strings (same format as `~/.ssh/authorized_keys`).

**The provisioner runs only once** (guarded by `/data/gitea/.provisioned`).
To re-provision after changes, run:

```bash
make reprovision
```

---

## SSH Key Format

Accepted algorithms: `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256/384/521`.

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... comment
```

Generate a new key pair:

```bash
ssh-keygen -t ed25519 -C "trainee01@range42" -f ~/.ssh/range42_trainee01
```

Paste the contents of `~/.ssh/range42_trainee01.pub` into the `ssh_keys` list.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GITEA_DOMAIN` | `localhost` | Public hostname |
| `GITEA_BASE_URL` | `http://localhost:3000` | Root URL shown in clone URLs |
| `GITEA_SECRET_KEY` | *(required)* | App secret — `openssl rand -hex 32` |
| `GITEA_INTERNAL_TOKEN` | *(required)* | Internal token — `gitea generate secret INTERNAL_TOKEN` |
| `GITEA_ADMIN_USER` | `gitea-admin` | Must match `admins[0].username` in `users.yml` |
| `GITEA_ADMIN_PASS` | `Admin1234!` | Must match `admins[0].password` in `users.yml` |
| `POSTGRES_USER` | `gitea` | DB user |
| `POSTGRES_PASSWORD` | `gitea` | DB password |
| `POSTGRES_DB` | `gitea` | DB name |
| `HTTP_PORT` | `3000` | Host port for HTTP |
| `SSH_PORT` | `2222` | Host port for SSH (avoids conflict with host sshd) |

---

## Troubleshooting

**Provisioner exits immediately with "Already provisioned"**
Remove the stamp and re-run: `make reprovision`

**`gitea admin user create` fails silently**
Check provisioner logs: `make logs-provisioner`
The stamp is NOT written on failure — restart the provisioner to retry.

**SSH key injection fails (HTTP 422)**
The key already exists in Gitea, or the key format is invalid.
Verify key format with `ssh-keygen -l -f <pubkey_file>`.

**Port 3000 already in use**
Set `HTTP_PORT=3001` (or any free port) in `.env`.
