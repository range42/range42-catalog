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
