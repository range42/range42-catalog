#!/usr/bin/env bash
# Refresh image-bundled MISP galaxy definitions in the persistent app/files
# volume. Docker initializes a new named volume from the image once, but does
# not update an existing volume when a newer image is deployed.
set -euo pipefail

SEED_DIR="${MISP_GALAXY_SEED_DIR:-/opt/misp-galaxy}"
TARGET_DIR="${MISP_GALAXY_TARGET_DIR:-/var/www/MISP/app/files/misp-galaxy}"
OWNER="${MISP_GALAXY_OWNER-www-data:www-data}"

log() { echo "[refresh-galaxy-files] $*"; }

if [ ! -d "${SEED_DIR}/clusters" ] || [ ! -d "${SEED_DIR}/galaxies" ]; then
    log "ERROR: bundled galaxy seed is incomplete at ${SEED_DIR}"
    exit 1
fi

log "Refreshing bundled galaxy definitions in ${TARGET_DIR} …"
mkdir -p "${TARGET_DIR}"
cp -a "${SEED_DIR}/." "${TARGET_DIR}/"

if [ -n "${OWNER}" ]; then
    chown -R "${OWNER}" "${TARGET_DIR}"
fi

log "Bundled galaxy definitions are current."
