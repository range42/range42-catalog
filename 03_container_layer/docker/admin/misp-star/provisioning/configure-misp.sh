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
        'encoding'    => 'utf8mb4 COLLATE utf8mb4_unicode_ci',
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

# config.default.php ships with 'live' => false. Patch it to true immediately so
# Apache never serves the "MISP is not live" login message, even if the cake
# Admin setSetting call at step 6 fails or behaves differently across MISP versions.
sed -i "s/'live'\s*=>\s*false/'live' => true/g" "${MISP_CONFIG_DIR}/config.php"
log "Patched config.php: MISP.live => true"

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

log "Loading bundled warning lists …"
${CAKE} Admin updateWarninglists 2>&1 || true

# ── 5. Initial admin user ─────────────────────────────────────────────────────

# Set the host organisation name BEFORE userInit so cake creates org 1 with this
# name. Setting it after userInit leaves org 1 as the config default (ORGNAME),
# which breaks sharing-group identity matching in the star (#221). Verified on a
# fresh DB: setSetting MISP.org works before userInit.
${CAKE} Admin setSetting "MISP.org" "${MISP_ORG:-Default Organisation}" || true

log "Creating initial admin via userInit …"
_INIT_OUT=$(${CAKE} userInit 2>&1 || true)
log "userInit output: ${_INIT_OUT}"

# ── 5a. Host org UUID (feat-1) ────────────────────────────────────────────────
# userInit gives org 1 a random UUID. Sync links orgs by UUID: without a fixed
# value the receiving instance duplicates the org as '<name>_<random>'.
# MISP_HOST_ORG_UUID wins; otherwise derive uuid5(MISP_ORG_UUID_NAMESPACE, MISP.org).
# python3 validates and normalises the UUID (lowercase canonical form), so the
# value interpolated into SQL is hex-and-dashes only. Fails hard: a wrong org
# UUID silently breaks the whole star.
_HOST_ORG_UUID=""
if [ -n "${MISP_HOST_ORG_UUID:-}" ]; then
    _HOST_ORG_UUID=$(python3 -c 'import uuid,sys; print(uuid.UUID(sys.argv[1]))' "${MISP_HOST_ORG_UUID}") \
        || { log "ERROR: MISP_HOST_ORG_UUID is not a valid UUID: ${MISP_HOST_ORG_UUID}"; exit 1; }
elif [ -n "${MISP_ORG_UUID_NAMESPACE:-}" ]; then
    _HOST_ORG_UUID=$(python3 -c 'import uuid,sys; print(uuid.uuid5(uuid.UUID(sys.argv[1]), sys.argv[2]))' \
        "${MISP_ORG_UUID_NAMESPACE}" "${MISP_ORG:-Default Organisation}") \
        || { log "ERROR: MISP_ORG_UUID_NAMESPACE is not a valid UUID: ${MISP_ORG_UUID_NAMESPACE}"; exit 1; }
fi
if [ -n "${_HOST_ORG_UUID}" ]; then
    log "Setting host org (id 1) UUID to ${_HOST_ORG_UUID} …"
    mysql -h "${DB_HOST:-db}" -P "${DB_PORT:-3306}" \
        -u "${MISP_DB_USER:-misp}" -p"${MISP_DB_PASSWORD}" \
        "${MISP_DB_NAME:-misp}" \
        -e "UPDATE organisations SET uuid='${_HOST_ORG_UUID}' WHERE id=1;"
fi

# ── 5b. Remove initial-install news thread ────────────────────────────────────
# userInit (and the bundled MYSQL.sql schema) create a "Initial Install" thread
# that appears as a news item on the MISP home page after every login.
# Delete it directly in the DB before Apache starts so no user ever sees it.
log "Removing initial-install news thread …"
mysql -h "${DB_HOST:-db}" -P "${DB_PORT:-3306}" \
    -u "${MISP_DB_USER:-misp}" -p"${MISP_DB_PASSWORD}" \
    "${MISP_DB_NAME:-misp}" \
    -e "SET FOREIGN_KEY_CHECKS=0; DELETE FROM posts; DELETE FROM threads; SET FOREIGN_KEY_CHECKS=1;" \
    2>&1 | grep -v "^$" || true

# ── 6. Core MISP settings ─────────────────────────────────────────────────────

log "Applying MISP settings …"

SALT="${MISP_SALT:-}"
[ -z "${SALT}" ] && SALT="$(openssl rand -hex 32)"

# ── Core identity & connectivity ─────────────────────────────────────────────
${CAKE} Admin setSetting "MISP.baseurl"                        "${MISP_BASEURL:-https://localhost}" || true
${CAKE} Admin setSetting "MISP.external_baseurl"               "${MISP_BASEURL:-https://localhost}" || true
# MISP.org is set earlier, before userInit (section 5), so org 1 gets this name (#221).
${CAKE} Admin setSetting "MISP.host_org_id"                    "1"                                  || true
${CAKE} Admin setSetting "MISP.python_bin"                     "/opt/misp-venv/bin/python3"         || true
${CAKE} Admin setSetting "MISP.email"                          "${MISP_ADMIN_EMAIL:-admin@misp.local}" || true

# Clear the default "Initial Install, please configure" login-page banner.
# config.default.php seeds welcome_text_top with this string; override it here.
${CAKE} Admin setSetting "MISP.welcome_text_top"    "" --force || true
${CAKE} Admin setSetting "MISP.welcome_text_bottom" "" --force || true

# ── Security ──────────────────────────────────────────────────────────────────
${CAKE} Admin setSetting "Security.salt"                              "${SALT}"  || true
${CAKE} Admin setSetting "Security.csp_enforce"                       "false"    || true
${CAKE} Admin setSetting "Security.allow_unsafe_apikey_named_param"   "false"    || true
${CAKE} Admin setSetting "Security.allow_unsafe_cleartext_apikey_logging" "false" || true

# ── GnuPG ────────────────────────────────────────────────────────────────────
# Generate a key so MISP's validator can find it by email; the lab does not
# use event signing but having the key clears the diagnostics warning.
_GPG_HOME="/var/www/MISP/.gnupg"
_GPG_EMAIL="${MISP_ADMIN_EMAIL:-admin@misp.local}"
mkdir -p "${_GPG_HOME}" && chmod 700 "${_GPG_HOME}"
if ! GNUPGHOME="${_GPG_HOME}" gpg --list-secret-keys "${_GPG_EMAIL}" &>/dev/null; then
    log "Generating GPG key for ${_GPG_EMAIL} …"
    GNUPGHOME="${_GPG_HOME}" gpg --batch --gen-key <<GPGEOF
%no-protection
Key-Type: RSA
Key-Length: 3072
Subkey-Type: RSA
Subkey-Length: 3072
Name-Real: MISP Admin
Name-Email: ${_GPG_EMAIL}
Expire-Date: 0
%commit
GPGEOF
fi
chown -R www-data:www-data "${_GPG_HOME}"
${CAKE} Admin setSetting "GnuPG.homedir" "${_GPG_HOME}"  || true
${CAKE} Admin setSetting "GnuPG.email"   "${_GPG_EMAIL}" || true
# GnuPG.password is deliberately omitted — key has no passphrase (%no-protection)
# and setting "" without --force triggers a validation error.

# ── Redis & background jobs ───────────────────────────────────────────────────
${CAKE} Admin setSetting "MISP.redis_host"                 "${REDIS_HOST:-redis}" || true
${CAKE} Admin setSetting "MISP.redis_port"                 "${REDIS_PORT:-6379}"  || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.enabled"    "true"                 || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_host" "${REDIS_HOST:-redis}" || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.redis_port" "${REDIS_PORT:-6379}"  || true
# Point MISP at the supervisord XML-RPC endpoint so it runs the workers (#219).
# supervisor_* credentials are generated per-instance in entrypoint.sh.
${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_host"     "127.0.0.1"                || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_port"     "9001"                     || true
${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_user"     "${SUPERVISOR_USER:-misp}" || true
# Discard stdout: setSetting echoes the value, which would print the password.
${CAKE} Admin setSetting "SimpleBackgroundJobs.supervisor_password" "${SUPERVISOR_PASSWORD:-}" >/dev/null 2>&1 || true

# ── Default distributions ─────────────────────────────────────────────────────
# Event distribution comes from env (0-4; 4 = sharing group). MISP never pushes
# distribution 0, so a star deployment must raise MISP_DEFAULT_DISTRIBUTION.
# Attribute/object/event-report are set to 'event' (inherit) so the event-level
# value is the only knob — pinning them to 0 would strip their data on push.
# Galaxy and analyst-data accept only 0-3 (Server.php v2.5.50:6442-6468); they
# do not gate event push and stay org-only.
${CAKE} Admin setSetting "MISP.default_event_distribution"          "${MISP_DEFAULT_DISTRIBUTION:-0}" || true
${CAKE} Admin setSetting "MISP.default_attribute_distribution"      "event" || true
${CAKE} Admin setSetting "MISP.default_object_distribution"         "event" || true
${CAKE} Admin setSetting "MISP.default_galaxy_distribution"         "0"     || true
${CAKE} Admin setSetting "MISP.default_eventreport_distribution"    "event" || true
${CAKE} Admin setSetting "MISP.default_analyst_data_distribution"   "0"     || true

# ── Plugins — misp-modules sidecar ───────────────────────────────────────────
# MISP's Module model builds the final URL as "$url:$port", so the URL must NOT
# include a port — only the host part. Port is set separately.
_MODULES_HOST="${MISP_MODULES_HOST:-http://misp-modules}"
_MODULES_PORT="${MISP_MODULES_PORT:-6666}"
${CAKE} Admin setSetting "Plugin.Enrichment_services_enable"    "true"              || true
${CAKE} Admin setSetting "Plugin.Enrichment_services_url"       "${_MODULES_HOST}"  || true
${CAKE} Admin setSetting "Plugin.Enrichment_services_port"      "${_MODULES_PORT}"  || true
${CAKE} Admin setSetting "Plugin.Enrichment_hover_enable"       "false"             || true
${CAKE} Admin setSetting "Plugin.Enrichment_hover_popover_only" "false"             || true
${CAKE} Admin setSetting "Plugin.Import_services_enable"        "true"              || true
${CAKE} Admin setSetting "Plugin.Import_services_url"           "${_MODULES_HOST}"  || true
${CAKE} Admin setSetting "Plugin.Import_services_port"          "${_MODULES_PORT}"  || true
${CAKE} Admin setSetting "Plugin.Export_services_enable"        "true"              || true
${CAKE} Admin setSetting "Plugin.Export_services_url"           "${_MODULES_HOST}"  || true
${CAKE} Admin setSetting "Plugin.Export_services_port"          "${_MODULES_PORT}"  || true
# Action, Cortex, and Workflow are not needed for this lab deployment.
${CAKE} Admin setSetting "Plugin.Action_services_enable"        "false"           || true
${CAKE} Admin setSetting "Plugin.Cortex_services_enable"        "false"           || true
${CAKE} Admin setSetting "Plugin.Workflow_enable"               "false"           || true

# pdfexport is a dynamic module setting — cake Admin setSetting rejects it because
# MISP only registers it after a live query to misp-modules (not available at boot).
# Write it directly to config.php so it is set from first boot.
php -r "
\$config = [];
include '${MISP_CONFIG_DIR}/config.php';
if (!isset(\$config['Plugin'])) \$config['Plugin'] = [];
\$config['Plugin']['Export_pdfexport_enabled'] = true;
\$out = '<?php' . PHP_EOL . '\$config = ' . var_export(\$config, true) . ';' . PHP_EOL;
file_put_contents('${MISP_CONFIG_DIR}/config.php', \$out);
" 2>&1 || log "WARNING: could not write Export_pdfexport_enabled to config.php"

# ── Taxonomy & galaxy import (after Redis is configured) ─────────────────────
# Running these here avoids the Redis "Connection refused" error that occurs
# when updateTaxonomies/updateGalaxies execute before MISP.redis_host is set.
log "Loading bundled taxonomies …"
${CAKE} Admin updateTaxonomies 2>&1 || true

log "Loading bundled galaxies …"
${CAKE} Admin updateGalaxies 2>&1 || true

# ── Emailing & logging ────────────────────────────────────────────────────────
${CAKE} Admin setSetting "MISP.disable_emailing"                    "true"  --force || true

# ── Live ──────────────────────────────────────────────────────────────────────
${CAKE} Admin setSetting "MISP.live" "true" --force || true

# ── 7. Retrieve admin auth-key ────────────────────────────────────────────────

log "Generating admin auth-key …"
# Advanced authkeys are enabled in MISP v2.5 — getAuthkey is blocked.
# change_authkey rotates to a new key and prints it.
# Retry up to 5 times in case the DB write takes a moment after migrations.
ADMIN_KEY=""
_CAKE_OUT=""
# Try the default seed email first, then the operator-configured email in case
# a previous provisioner run already renamed the account.
for _email in "admin@admin.test" "${MISP_ADMIN_EMAIL:-admin@misp.local}"; do
    _CAKE_OUT=$(${CAKE} user change_authkey "${_email}" 2>&1 || true)
    log "change_authkey(${_email}) output: ${_CAKE_OUT}"
    ADMIN_KEY=$(echo "${_CAKE_OUT}" | grep -oP 'new key created: \K\S+' || true)
    [ -n "${ADMIN_KEY}" ] || ADMIN_KEY=$(echo "${_CAKE_OUT}" | grep -oP 'New authkey for [^:]+: \K\S+' || true)
    [ -n "${ADMIN_KEY}" ] || ADMIN_KEY=$(echo "${_CAKE_OUT}" | grep -oP 'New key: \K\S+' || true)
    [ -n "${ADMIN_KEY}" ] && break
done

if [ -z "${ADMIN_KEY}" ]; then
    log "ERROR: could not generate admin auth-key after 5 attempts. Last output: ${_CAKE_OUT}"
    exit 1
fi

# Only write the file once we have a real key so provisioners waiting on
# a non-empty file are not unblocked by a blank line.
printf '%s' "${ADMIN_KEY}" > /keys/admin-authkey
chmod 600 /keys/admin-authkey
log "Admin auth-key written to /keys/admin-authkey"
