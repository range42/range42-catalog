#!/usr/bin/env bash
# provision-orgs.sh — creates MISP organisations for player teams and instructors.
# Called by provision.sh before user provisioning.
# Idempotent: skips organisations that already exist by name.
#
# Reads:
#   MISP_STAR_MODE          — hub (default) or spoke (feat-1)
#   MISP_TEAMS              — comma-separated team names (default: team-blue,team-red)
#   MISP_INSTRUCTOR_ORG     — instructor org name        (default: instructors)
#   MISP_ORG_UUID_NAMESPACE — optional UUIDv5 namespace for deterministic org UUIDs
#
# Writes:
#   /keys/org-ids.env   — env-style mapping, e.g. MISP_ORG_ID_TEAM_BLUE=3
set -euo pipefail

MISP_URL="https://misp"
ADMIN_KEY_FILE="/keys/admin-authkey"
ORG_IDS_FILE="/keys/org-ids.env"

log()  { echo "[provision-orgs] $*" >&2; }
fail() { echo "[provision-orgs] ERROR: $*" >&2; exit 1; }

# Fail fast on a typo: a spoke silently running as hub would only surface at
# pairing time. provision.sh runs this script first, so one guard covers the
# whole provisioner pipeline.
case "${MISP_STAR_MODE:-hub}" in
    hub|spoke) ;;
    *) fail "MISP_STAR_MODE must be 'hub' or 'spoke', got: '${MISP_STAR_MODE}'" ;;
esac

# ── Spoke mode (feat-1) ───────────────────────────────────────────────────────
# On a spoke, org 1 IS the team org: configure-misp.sh already created it with
# the configured name (MISP_ORG) and UUID. No instructor org, no extra orgs —
# only the org-ids mapping is written so provision-users.sh targets org 1.
if [ "${MISP_STAR_MODE:-hub}" = "spoke" ]; then
    team_name=$(echo "${MISP_ORG:-Default Organisation}" | tr -d '[:space:]')
    env_key="MISP_ORG_ID_$(echo "${team_name}" | tr '[:lower:]-' '[:upper:]_')"
    echo "${env_key}=1" > "${ORG_IDS_FILE}"
    chmod 600 "${ORG_IDS_FILE}"
    log "Spoke mode: org 1 = '${team_name}' — wrote ${ORG_IDS_FILE}, no orgs created."
    exit 0
fi

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

# Creates an org and returns its new ID.
# When MISP_ORG_UUID_NAMESPACE is set, the org gets uuid5(namespace, name) —
# the same name yields the same UUID on every instance of the star, so sync
# matches the org by UUID instead of duplicating it as '<name>_<random>' (feat-1).
create_org() {
    local name="$1"
    local resp uuid_line=""
    if [ -n "${MISP_ORG_UUID_NAMESPACE:-}" ]; then
        local org_uuid
        org_uuid=$(python3 -c 'import uuid,sys; print(uuid.uuid5(uuid.UUID(sys.argv[1]), sys.argv[2]))' \
            "${MISP_ORG_UUID_NAMESPACE}" "${name}") \
            || fail "MISP_ORG_UUID_NAMESPACE is not a valid UUID: ${MISP_ORG_UUID_NAMESPACE}"
        uuid_line="\"uuid\": \"${org_uuid}\","
    fi
    resp=$(misp_post "/admin/organisations/add" "$(cat <<JSON
{
  ${uuid_line}
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

# ── Build org list ────────────────────────────────────────────────────────────

INSTRUCTOR_ORG="${MISP_INSTRUCTOR_ORG:-instructors}"
IFS=',' read -ra TEAM_LIST <<< "${MISP_TEAMS:-team-blue,team-red}"

ALL_ORGS=("${INSTRUCTOR_ORG}")
for t in "${TEAM_LIST[@]}"; do
    ALL_ORGS+=("${t}")
done

log "Orgs to provision: ${ALL_ORGS[*]}"

# ── Create orgs ───────────────────────────────────────────────────────────────

: > "${ORG_IDS_FILE}"

for raw_name in "${ALL_ORGS[@]}"; do
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

    # Convert name to UPPER_SNAKE for the env key, e.g. team-blue → TEAM_BLUE
    env_key="MISP_ORG_ID_$(echo "${org_name}" | tr '[:lower:]-' '[:upper:]_')"
    echo "${env_key}=${org_id}" >> "${ORG_IDS_FILE}"
done

chmod 600 "${ORG_IDS_FILE}"
log "Org IDs written to ${ORG_IDS_FILE}"
