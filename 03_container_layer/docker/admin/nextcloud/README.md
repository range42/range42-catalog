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

Edit `provisioning/users.yml` before the first `make up`:

```yaml
admins:
  - username: nc-admin2
    email: admin2@range42.local
    password: "Admin1234!"
    display_name: "NC Admin 2"

users:
  - username: trainee01
    email: trainee01@range42.local
    password: "Trainee1234!"
    display_name: "Trainee 01"
```

- `admins[]` entries are created and added to the Nextcloud `admin` group.
- `users[]` entries are regular accounts.
- `nc-admin` (set via `NC_ADMIN_USER`) is created automatically by Nextcloud — do not repeat it here.
- An app password is auto-generated for every user and written to `/tokens/tokens.txt`.

**The provisioner runs only once** (guarded by `/tokens/.provisioned`).
To re-provision after changes, run:

```bash
make reprovision
```

---

## App Password Retrieval

App passwords are written to the `nextcloud-tokens` volume during provisioning.
Retrieve them at any time:

```bash
make tokens
```

Example output:

```
nc-admin2: <app-password-string>
trainee01: <app-password-string>
trainee02: <app-password-string>
trainee03: <app-password-string>
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
