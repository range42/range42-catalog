#!/bin/sh
# Enable training-required apps on first installation.
# Runs as www-data inside the nextcloud container via post-installation hooks.
set -e

OCC="php /var/www/html/occ"

for app in calendar contacts deck notes forms polls talk mail richdocuments twofactor_totp; do
  if $OCC app:enable "${app}" 2>/dev/null; then
    echo "[hook] enabled app: ${app}"
  else
    echo "[hook] warn: could not enable ${app} (may not be bundled — skipping)"
  fi
done
