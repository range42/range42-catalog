#!/usr/bin/env bash
# provision-orgs.sh — creates MISP organisations for player teams and instructors.
# Called by provision.sh before user provisioning.
# Idempotent: skips organisations that already exist by name.
#
# Reads:
#   MISP_TEAMS          — comma-separated team names (default: team-blue,team-red)
#   MISP_INSTRUCTOR_ORG — instructor org name        (default: instructors)
#
# Writes:
#   /keys/org-ids.env   — env-style mapping, e.g. MISP_ORG_ID_TEAM_BLUE=3
set -euo pipefail

MISP_URL="https://misp"
ADMIN_KEY_FILE="/keys/admin-authkey"
ORG_IDS_FILE="/keys/org-ids.env"

log()  { echo "[provision-orgs] $*" >&2; }
fail() { echo "[provision-orgs] ERROR: $*" >&2; exit 1; }

# ── Wait for admin auth-key ───────────────────────────────────────────────────

log "Waiting for admin auth-key …"
ADMIN_KEY=""
for i in $(seq 1 60); do
    ADMIN_KEY=$(tr -d '[:space:]' < "${ADMIN_KEY_FILE}" 2>/dev/null || true)
    [ -n "${ADMIN_KEY}" ] && break
    sleep 5
done
[ -n "${ADMIN_KEY}" ] || fail "admin-authkey did not appear within 300 s"
log "Admin auth-key loaded."

# ── REST helpers ──────────────────────────────────────────────────────────────

misp_get() {
    curl -sfk \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Accept: application/json" \
        "${MISP_URL}${1}"
}

misp_post() {
    curl -sk \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST \
        -d "${2}" \
        "${MISP_URL}${1}"
}

# Returns the org ID for the given name, or empty string if not found.
get_org_id() {
    local name="$1"
    misp_get "/organisations/index" | python3 -c "
import sys, json
data = json.load(sys.stdin)
target = sys.argv[1]
for entry in data:
    org = entry.get('Organisation', {})
    if org.get('name') == target:
        print(org.get('id', ''))
        sys.exit(0)
" "${name}" 2>/dev/null || true
}

# Renames MISP's default org (id=1) to the given name and returns its ID.
rename_host_org() {
    local name="$1"
    local resp
    resp=$(misp_post "/admin/organisations/edit/1" "$(cat <<JSON
{
  "name":        "${name}",
  "nationality": "International",
  "local":       true
}
JSON
)" 2>&1 || true)
    log "rename_host_org('${name}') raw response: ${resp}"
    echo "${resp}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('Organisation', {}).get('id', ''))
" 2>/dev/null || true
}

# Creates an org and returns its new ID.
create_org() {
    local name="$1"
    local resp
    resp=$(misp_post "/admin/organisations/add" "$(cat <<JSON
{
  "name":        "${name}",
  "nationality": "International",
  "local":       true,
  "type":        "",
  "sector":      ""
}
JSON
)" 2>&1 || true)
    log "create_org('${name}') raw response: ${resp}"
    echo "${resp}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('Organisation', {}).get('id', ''))
" 2>/dev/null || true
}

# ── Resolve names ─────────────────────────────────────────────────────────────

# Instructor org falls back to MISP_ORG so that a blank MISP_INSTRUCTOR_ORG in
# .env automatically reuses the host org name without extra configuration.
INSTRUCTOR_ORG="${MISP_INSTRUCTOR_ORG:-${MISP_ORG:-Range42}}"
IFS=',' read -ra TEAM_LIST <<< "${MISP_TEAMS:-team-blue,team-red}"

log "Instructor org: ${INSTRUCTOR_ORG}"
log "Team orgs: ${TEAM_LIST[*]}"

: > "${ORG_IDS_FILE}"

# ── Instructor org — reuse MISP host org (id=1) ───────────────────────────────
# cake userInit creates org 1 with a generic placeholder name. Rename it to the
# instructor org name so the admin user is already in the right org.

instr_id=$(get_org_id "${INSTRUCTOR_ORG}")
if [ -n "${instr_id}" ]; then
    log "Instructor org '${INSTRUCTOR_ORG}' already exists (id=${instr_id}) — skipping rename."
else
    log "Renaming MISP host org (id=1) to '${INSTRUCTOR_ORG}' …"
    instr_id=$(rename_host_org "${INSTRUCTOR_ORG}")
    [ -n "${instr_id}" ] || fail "Failed to rename host org to '${INSTRUCTOR_ORG}' — empty ID returned."
    log "Host org renamed to '${INSTRUCTOR_ORG}' (id=${instr_id})."
fi

instr_env_key="MISP_ORG_ID_$(echo "${INSTRUCTOR_ORG}" | tr '[:lower:]-' '[:upper:]_')"
echo "${instr_env_key}=${instr_id}" >> "${ORG_IDS_FILE}"

# ── Team orgs — create if absent ─────────────────────────────────────────────

for raw_name in "${TEAM_LIST[@]}"; do
    org_name=$(echo "${raw_name}" | tr -d '[:space:]')
    [ -z "${org_name}" ] && continue

    org_id=$(get_org_id "${org_name}")

    if [ -n "${org_id}" ]; then
        log "Org '${org_name}' already exists (id=${org_id}) — skipping."
    else
        log "Creating org '${org_name}' …"
        org_id=$(create_org "${org_name}")
        [ -n "${org_id}" ] || fail "Failed to create org '${org_name}' — empty ID returned."
        log "Org '${org_name}' created (id=${org_id})."
    fi

    env_key="MISP_ORG_ID_$(echo "${org_name}" | tr '[:lower:]-' '[:upper:]_')"
    echo "${env_key}=${org_id}" >> "${ORG_IDS_FILE}"
done

chmod 600 "${ORG_IDS_FILE}"
log "Org IDs written to ${ORG_IDS_FILE}"
