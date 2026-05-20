#!/usr/bin/env bash
# Provisioner container entrypoint — runs ONCE after MISP is healthy.
#
# Reads the admin auth-key that entrypoint.sh wrote to /keys/admin-authkey,
# then uses the MISP REST API to:
#   1. Rename/update the default admin account
#   2. Create an optional second admin
#   3. Create the reader user  (role_id=6 — Read Only)
#   4. Create the writer user  (role_id=4 — Publisher)
#   5. Emit all API keys to /keys/api-keys.txt
#
# Role IDs (MISP defaults, verified via `cake role list`):
#   1 = Site Admin    4 = Publisher (writer)
#   2 = Org Admin     5 = Sync User
#   3 = User          6 = Read Only (reader)
set -euo pipefail

MISP_URL="http://misp"
KEYS_FILE="/keys/api-keys.txt"
ADMIN_KEY_FILE="/keys/admin-authkey"

log()  { echo "[provisioner] $*"; }
fail() { echo "[provisioner] ERROR: $*" >&2; exit 1; }

# ── Idempotency guard ─────────────────────────────────────────────────────────

if [ -s "${KEYS_FILE}" ]; then
    log "Keys file already exists — provisioning already done. Exiting."
    exit 0
fi

# ── Wait for admin auth-key ───────────────────────────────────────────────────

log "Waiting for admin auth-key …"
for i in $(seq 1 60); do
    if [ -s "${ADMIN_KEY_FILE}" ]; then break; fi
    sleep 5
done
[ -s "${ADMIN_KEY_FILE}" ] || fail "admin-authkey never appeared in /keys/"

ADMIN_KEY=$(cat "${ADMIN_KEY_FILE}" | tr -d '[:space:]')
[ -n "${ADMIN_KEY}" ] || fail "admin-authkey is empty"
log "Admin auth-key loaded."

# ── Helper: call MISP REST API ────────────────────────────────────────────────

misp_post() {
    local path="$1" body="$2"
    curl -sf \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST \
        -d "${body}" \
        "${MISP_URL}${path}"
}

misp_put() {
    local path="$1" body="$2"
    curl -sf \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X PUT \
        -d "${body}" \
        "${MISP_URL}${path}"
}

# ── 1. Update default admin account ──────────────────────────────────────────

log "Updating admin account (admin@admin.test → ${MISP_ADMIN_EMAIL:-admin@misp.local}) …"
misp_put "/admin/users/edit/1" "$(cat <<JSON
{
  "email":            "${MISP_ADMIN_EMAIL:-admin@misp.local}",
  "password":         "${MISP_ADMIN_PASSWORD:-Admin1234!}",
  "confirm_password": "${MISP_ADMIN_PASSWORD:-Admin1234!}",
  "change_pw":        0,
  "role_id":          1,
  "org_id":           1,
  "termsaccepted":    1
}
JSON
)" > /dev/null
log "Admin account updated."

# ── 2. Optional second admin ──────────────────────────────────────────────────

ADMIN2_KEY=""
if [ -n "${MISP_ADMIN2_EMAIL:-}" ] && [ -n "${MISP_ADMIN2_PASSWORD:-}" ]; then
    log "Creating second admin: ${MISP_ADMIN2_EMAIL} …"
    ADMIN2_RESP=$(misp_post "/admin/users/add" "$(cat <<JSON
{
  "email":            "${MISP_ADMIN2_EMAIL}",
  "password":         "${MISP_ADMIN2_PASSWORD}",
  "confirm_password": "${MISP_ADMIN2_PASSWORD}",
  "role_id":          1,
  "org_id":           1,
  "change_pw":        0,
  "termsaccepted":    1
}
JSON
)")
    ADMIN2_KEY=$(echo "${ADMIN2_RESP}" | grep -oP '"authkey"\s*:\s*"\K[^"]+' || true)
    log "Second admin created."
fi

# ── 3. Reader user (role_id=6 — Read Only) ───────────────────────────────────

log "Creating reader: ${MISP_READER_EMAIL:-reader@misp.local} …"
READER_RESP=$(misp_post "/admin/users/add" "$(cat <<JSON
{
  "email":            "${MISP_READER_EMAIL:-reader@misp.local}",
  "password":         "${MISP_READER_PASSWORD:-Reader1234!XYZ}",
  "confirm_password": "${MISP_READER_PASSWORD:-Reader1234!XYZ}",
  "role_id":          6,
  "org_id":           1,
  "change_pw":        0,
  "termsaccepted":    1
}
JSON
)")
READER_KEY=$(echo "${READER_RESP}" | grep -oP '"authkey"\s*:\s*"\K[^"]+' || true)
log "Reader created."

# ── 4. Writer user (role_id=4 — Publisher) ───────────────────────────────────

log "Creating writer: ${MISP_WRITER_EMAIL:-writer@misp.local} …"
WRITER_RESP=$(misp_post "/admin/users/add" "$(cat <<JSON
{
  "email":            "${MISP_WRITER_EMAIL:-writer@misp.local}",
  "password":         "${MISP_WRITER_PASSWORD:-Writer1234!XYZ}",
  "confirm_password": "${MISP_WRITER_PASSWORD:-Writer1234!XYZ}",
  "role_id":          4,
  "org_id":           1,
  "change_pw":        0,
  "termsaccepted":    1
}
JSON
)")
WRITER_KEY=$(echo "${WRITER_RESP}" | grep -oP '"authkey"\s*:\s*"\K[^"]+' || true)
log "Writer created."

# ── 5. Write keys file ────────────────────────────────────────────────────────

log "Writing ${KEYS_FILE} …"
{
    echo "# MISP API keys — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "# Keep this file secret."
    echo ""
    echo "MISP_BASEURL=${MISP_BASEURL:-http://localhost}"
    echo ""
    echo "# Admin (${MISP_ADMIN_EMAIL:-admin@misp.local}) — role: Site Admin"
    echo "MISP_ADMIN_KEY=${ADMIN_KEY}"
    echo ""
    if [ -n "${ADMIN2_KEY}" ]; then
        echo "# Admin2 (${MISP_ADMIN2_EMAIL:-}) — role: Site Admin"
        echo "MISP_ADMIN2_KEY=${ADMIN2_KEY}"
        echo ""
    fi
    echo "# Reader (${MISP_READER_EMAIL:-reader@misp.local}) — role: Read Only"
    echo "MISP_READER_KEY=${READER_KEY}"
    echo ""
    echo "# Writer (${MISP_WRITER_EMAIL:-writer@misp.local}) — role: Publisher"
    echo "MISP_WRITER_KEY=${WRITER_KEY}"
} > "${KEYS_FILE}"

chmod 600 "${KEYS_FILE}"

log "Provisioning complete."
log "Retrieve keys: docker compose exec misp cat ${KEYS_FILE}"
log "         or:   docker compose cp misp:${KEYS_FILE} ./api-keys.txt"
