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

# Collabora CODE — three-URL WOPI configuration:
#   wopi_url         : internal Collabora URL (Nextcloud→Collabora discovery, no TLS in Docker)
#   public_wopi_url  : external Collabora URL (browser→Collabora, through nginx TLS proxy)
#   wopi_callback_url: internal Nextcloud URL (Collabora→Nextcloud WOPI callbacks)
#
# wopi_callback_url is the hairpin-NAT fix: Collabora embeds this URL in WOPISrc so
# CheckFileInfo callbacks go to "http://nextcloud" (Docker service name) instead of the
# external IP, bypassing the Docker bridge hairpin-NAT block.
# Collabora's coolwsd.xml must have <host allow="true">nextcloud</host> in the wopi section.
$OCC config:app:set richdocuments wopi_url \
  --value="http://collabora:9980" 2>/dev/null || true
$OCC config:app:set richdocuments public_wopi_url \
  --value="${NC_COLLABORA_URL:-https://localhost:8443}" 2>/dev/null || true
$OCC config:app:set richdocuments wopi_callback_url \
  --value="http://nextcloud" 2>/dev/null || true
$OCC config:app:set richdocuments wopi_allowlist \
  --value="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16" 2>/dev/null || true
echo "[hook] Collabora wopi_url: http://collabora:9980 / public: ${NC_COLLABORA_URL:-https://localhost:8443} / callback: http://nextcloud"

# Enforce 2FA (TOTP) for instructors group. twofactorauth:enforce stores a group
# list in config; it is safe to set before the group exists — Nextcloud checks it at login time.
$OCC twofactorauth:enforce --on --group=instructors 2>/dev/null || true
echo "[hook] 2FA enforcement enabled for group: instructors"
