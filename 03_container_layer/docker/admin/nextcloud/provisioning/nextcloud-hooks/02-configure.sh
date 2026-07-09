#!/bin/sh
# Apply system-wide Nextcloud configuration on first installation.
# Runs as www-data inside the nextcloud container via post-installation hooks.
set -e

OCC="php /var/www/html/occ"

# Keep file versions for up to 90 days (auto-manages space within that window)
$OCC config:app:set files versions_retention_obligation --value="auto, 90"
echo "[hook] files version retention: auto, 90 days"

# Purge trash after 30 days
$OCC config:app:set files_trashbin trashbin_retention_obligation --value="auto, 30"
echo "[hook] trash retention: auto, 30 days"

# Enable activity feed grouping
$OCC config:app:set activity activitygrouping --value="1" 2>/dev/null || true
echo "[hook] activity grouping enabled"

# Disable HIBP breached-password check so provisioner can create training accounts.
# Training passwords (Admin1234!, Trainee1234!) appear in the pwnedpasswords.com dataset.
# enforceNonCommonPassword covers the local 1M-list check; enforceHaveIBeenPwned covers
# the live HIBP API check — both must be disabled.
$OCC config:app:set password_policy enforceNonCommonPassword --value="0" 2>/dev/null || true
$OCC config:app:set password_policy enforceHaveIBeenPwned --value="0" 2>/dev/null || true
echo "[hook] password breach checks disabled (training env)"

# Collabora CODE — point richdocuments at the nginx-proxied Collabora endpoint.
# NC_COLLABORA_URL is set by docker-compose from the host environment (or defaults to localhost:9443).
# wopi_allowlist covers the RFC-1918 ranges used inside Docker networks.
$OCC config:app:set richdocuments wopi_url \
  --value="${NC_COLLABORA_URL:-https://localhost:9443}" 2>/dev/null || true
$OCC config:app:set richdocuments wopi_allowlist \
  --value="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16" 2>/dev/null || true
echo "[hook] Collabora WOPI URL: ${NC_COLLABORA_URL:-https://localhost:9443}"

# Enforce 2FA (TOTP) for instructors group. twofactorauth:enforce stores a group
# list in config; it is safe to set before the group exists — Nextcloud checks it at login time.
$OCC twofactorauth:enforce --on --group=instructors 2>/dev/null || true
echo "[hook] 2FA enforcement enabled for group: instructors"
