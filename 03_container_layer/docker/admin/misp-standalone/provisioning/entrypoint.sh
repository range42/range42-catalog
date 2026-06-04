#!/usr/bin/env bash
# MISP container entrypoint.
# On first boot: waits for deps, bootstraps MISP, writes admin auth-key.
# On subsequent boots: skips bootstrap and starts Apache directly.
set -euo pipefail

SENTINEL="/keys/.bootstrapped"

log() { echo "[entrypoint] $*"; }

# ── Wait for MariaDB and Redis ────────────────────────────────────────────────

log "Waiting for database (${DB_HOST:-db}:${DB_PORT:-3306}) …"
/provisioning/wait-for-tcp.sh "${DB_HOST:-db}" "${DB_PORT:-3306}" 120

log "Waiting for Redis (${REDIS_HOST:-redis}:${REDIS_PORT:-6379}) …"
/provisioning/wait-for-tcp.sh "${REDIS_HOST:-redis}" "${REDIS_PORT:-6379}" 60

# ── TLS certificate ────────────────────────────────────────────────────────────
# If MISP_TLS_CERT / MISP_TLS_KEY point to operator-provided files, symlink them
# into /certs/ so Apache always reads from a fixed path.
# Otherwise generate a self-signed cert on first boot (or if the cert is missing).

CERT_DST="/certs/misp.crt"
KEY_DST="/certs/misp.key"

if [ -n "${MISP_TLS_CERT:-}" ] && [ -f "${MISP_TLS_CERT}" ] \
   && [ -n "${MISP_TLS_KEY:-}" ]  && [ -f "${MISP_TLS_KEY}" ]; then
    log "Using operator-provided TLS cert: ${MISP_TLS_CERT}"
    ln -sf "${MISP_TLS_CERT}" "${CERT_DST}"
    ln -sf "${MISP_TLS_KEY}"  "${KEY_DST}"
elif [ ! -f "${CERT_DST}" ] || [ ! -f "${KEY_DST}" ]; then
    log "Generating self-signed TLS cert (CN=${MISP_HOSTNAME:-localhost}) …"
    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:4096 \
        -keyout "${KEY_DST}" \
        -out    "${CERT_DST}" \
        -subj   "/CN=${MISP_HOSTNAME:-localhost}/O=range42/C=FR" \
        -addext "subjectAltName=DNS:${MISP_HOSTNAME:-localhost},DNS:localhost,IP:127.0.0.1" \
        2>/dev/null
    chmod 644 "${CERT_DST}"
    chmod 600 "${KEY_DST}"
    log "Self-signed cert written to ${CERT_DST}"
else
    log "TLS cert already present at ${CERT_DST} — skipping generation."
fi

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
