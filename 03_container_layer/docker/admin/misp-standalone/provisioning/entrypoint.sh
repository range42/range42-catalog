#!/usr/bin/env bash
# MISP container entrypoint.
# On first boot: waits for deps, bootstraps MISP, writes admin auth-key.
# On subsequent boots: skips bootstrap and starts Apache directly.
set -euo pipefail

SENTINEL="/var/www/MISP/.bootstrapped"

log() { echo "[entrypoint] $*"; }

# ── Wait for MariaDB and Redis ────────────────────────────────────────────────

log "Waiting for database (${DB_HOST:-db}:${DB_PORT:-3306}) …"
/provisioning/wait-for-tcp.sh "${DB_HOST:-db}" "${DB_PORT:-3306}" 120

log "Waiting for Redis (${REDIS_HOST:-redis}:${REDIS_PORT:-6379}) …"
/provisioning/wait-for-tcp.sh "${REDIS_HOST:-redis}" "${REDIS_PORT:-6379}" 60

# ── First-boot bootstrap ──────────────────────────────────────────────────────

if [ ! -f "${SENTINEL}" ]; then
    log "First boot — running MISP bootstrap …"
    # shellcheck source=configure-misp.sh
    . /provisioning/configure-misp.sh
    touch "${SENTINEL}"
    log "Bootstrap complete."
else
    log "Bootstrap already done — skipping."
fi

# ── Start services ────────────────────────────────────────────────────────────

log "Starting supervisord …"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
