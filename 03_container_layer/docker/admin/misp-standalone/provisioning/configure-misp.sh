#!/usr/bin/env bash
# Sourced by entrypoint.sh on first boot.
# Writes database.php, seeds the schema, configures MISP via cake,
# creates the initial admin user, and writes its auth-key to /keys/.
set -euo pipefail

# Use the cake bash wrapper directly — running `php cake` (a shell script) is a no-op.
CAKE="runuser -u www-data -- /var/www/MISP/app/Console/cake"
MISP_CONFIG_DIR="/var/www/MISP/app/Config"

log() { echo "[configure] $*"; }

# ── 1. Database config ────────────────────────────────────────────────────────

log "Writing database.php …"
cat > "${MISP_CONFIG_DIR}/database.php" <<PHP
<?php
class DATABASE_CONFIG {
    public \$default = [
        'datasource'  => 'Database/Mysql',
        'persistent'  => false,
        'host'        => '${DB_HOST:-db}',
        'login'       => '${MISP_DB_USER:-misp}',
        'password'    => '${MISP_DB_PASSWORD}',
        'database'    => '${MISP_DB_NAME:-misp}',
        'port'        => '${DB_PORT:-3306}',
        'encoding'    => 'utf8mb4',
    ];
}
PHP
chown www-data:www-data "${MISP_CONFIG_DIR}/database.php"
chmod 640 "${MISP_CONFIG_DIR}/database.php"

# ── 2. Baseline config.php (from template if missing) ────────────────────────

for tmpl in config core bootstrap; do
    if [ ! -f "${MISP_CONFIG_DIR}/${tmpl}.php" ]; then
        log "Copying ${tmpl}.default.php → ${tmpl}.php …"
        cp "${MISP_CONFIG_DIR}/${tmpl}.default.php" "${MISP_CONFIG_DIR}/${tmpl}.php"
        chown www-data:www-data "${MISP_CONFIG_DIR}/${tmpl}.php"
        chmod 640 "${MISP_CONFIG_DIR}/${tmpl}.php"
    fi
done

# ── 3. Seed base schema (only when DB is empty) ───────────────────────────────
#
# cake Admin runUpdates applies migrations but requires base tables to exist.
# INSTALL/MYSQL.sql creates them. We guard with a table count so a container
# rebuild against a pre-existing DB volume doesn't fail on duplicate tables.

SCHEMA_SQL="/var/www/MISP/INSTALL/MYSQL.sql"

TABLE_COUNT=$(mysql -h "${DB_HOST:-db}" -P "${DB_PORT:-3306}" \
    -u "${MISP_DB_USER:-misp}" -p"${MISP_DB_PASSWORD}" \
    --skip-column-names --batch \
    -e "SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema='${MISP_DB_NAME:-misp}';" 2>/dev/null || echo "0")

if [ "${TABLE_COUNT}" -eq "0" ]; then
    if [ -f "${SCHEMA_SQL}" ]; then
        log "Seeding base schema from ${SCHEMA_SQL} …"
        mysql -h "${DB_HOST:-db}" -P "${DB_PORT:-3306}" \
              -u "${MISP_DB_USER:-misp}" -p"${MISP_DB_PASSWORD}" \
              "${MISP_DB_NAME:-misp}" < "${SCHEMA_SQL}"
    else
        log "WARNING: ${SCHEMA_SQL} not found — runUpdates may fail on empty DB"
    fi
else
    log "Schema already present (${TABLE_COUNT} tables) — skipping seed."
fi

# ── 4. Run pending migrations ─────────────────────────────────────────────────

log "Running pending DB migrations …"
${CAKE} Admin runUpdates 2>&1 || true

# ── 5. Initial admin user ─────────────────────────────────────────────────────

log "Creating initial admin via userInit …"
${CAKE} userInit -q 2>&1 || true

# ── 6. Core MISP settings ─────────────────────────────────────────────────────

log "Applying MISP settings …"

SALT="${MISP_SALT:-}"
[ -z "${SALT}" ] && SALT="$(openssl rand -hex 32)"

${CAKE} Admin setSetting "MISP.baseurl"                    "${MISP_BASEURL:-http://localhost}"  || true
${CAKE} Admin setSetting "MISP.org"                        "${MISP_ORG:-Default Organisation}"  || true
${CAKE} Admin setSetting "MISP.host_org_id"                "1"                                  || true
${CAKE} Admin setSetting "Security.salt"                   "${SALT}"                             || true
${CAKE} Admin setSetting "MISP.disable_emailing"           "true"  --force                      || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.enabled"    "true"                               || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_host" "${REDIS_HOST:-redis}"               || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_port" "${REDIS_PORT:-6379}"                || true

# ── 7. Retrieve admin auth-key ────────────────────────────────────────────────

log "Generating admin auth-key …"
# Advanced authkeys are enabled in MISP v2.5 — getAuthkey is blocked.
# change_authkey rotates to a new key and prints it.
ADMIN_KEY=$(${CAKE} user change_authkey "admin@admin.test" 2>/dev/null \
    | grep -oP '(?<=new key created: )\S+' || true)

if [ -z "${ADMIN_KEY}" ]; then
    log "WARNING: could not generate auth-key — provisioner may fail."
fi

echo "${ADMIN_KEY}" > /keys/admin-authkey
chmod 600 /keys/admin-authkey
log "Admin auth-key written to /keys/admin-authkey"
