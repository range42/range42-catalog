#!/usr/bin/env bash
# provision-sharing-groups.sh — creates MISP sharing groups across all orgs.
# Called by provision.sh after provision-orgs.sh.
# Idempotent: skips groups that already exist by name.
#
# Reads:
#   MISP_SHARING_GROUP_NAME — display name of the group (default: all-teams)
#   MISP_TEAMS              — comma-separated team names  (default: team-blue,team-red)
#   MISP_INSTRUCTOR_ORG     — instructor org name         (default: MISP_ORG)
#   /keys/org-ids.env       — org ID map written by provision-orgs.sh
set -euo pipefail

LOG_TAG="provision-sharing-groups"
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
ORG_IDS_FILE="/keys/org-ids.env"

# Returns the sharing group ID for the given name, or empty string if not found.
get_sg_id() {
    local name="$1"
    misp_get "/sharingGroups/index" | python3 -c "
import sys, json
data = json.load(sys.stdin)
entries = data.get('response', []) if isinstance(data, dict) else data
target = sys.argv[1]
for entry in entries:
    sg = entry.get('SharingGroup', {})
    if sg.get('name') == target:
        print(sg.get('id', ''))
        sys.exit(0)
" "${name}"
}

# ── Load org IDs ──────────────────────────────────────────────────────────────

[ -f "${ORG_IDS_FILE}" ] || fail "${ORG_IDS_FILE} not found — run provision-orgs.sh first"
# shellcheck source=/dev/null
. "${ORG_IDS_FILE}"

# ── Build member org list ─────────────────────────────────────────────────────

IFS=',' read -ra TEAM_LIST <<< "${MISP_TEAMS:-team-blue,team-red}"

ALL_ORGS=("${INSTRUCTOR_ORG}")
for t in "${TEAM_LIST[@]}"; do
    ALL_ORGS+=("$(echo "${t}" | tr -d '[:space:]')")
done

# Resolve org IDs from the env file values sourced above.
ORG_IDS=()
for org_name in "${ALL_ORGS[@]}"; do
    env_key="$(org_env_key "${org_name}")"
    org_id="${!env_key:-}"
    if [ -z "${org_id}" ]; then
        log "WARNING: no ID found for org '${org_name}' — skipping from sharing group."
        continue
    fi
    ORG_IDS+=("${org_id}")
done

[ "${#ORG_IDS[@]}" -gt 0 ] || fail "No valid org IDs found — cannot create sharing group."

# ── Create sharing group ──────────────────────────────────────────────────────

SG_NAME="${MISP_SHARING_GROUP_NAME:-all-teams}"

sg_id=$(get_sg_id "${SG_NAME}")

if [ -n "${sg_id}" ]; then
    log "Sharing group '${SG_NAME}' already exists (id=${sg_id}) — skipping."
else
    log "Creating sharing group '${SG_NAME}' …"
    resp=$(misp_post "/sharingGroups/add" "$(cat <<JSON
{
  "name":          "${SG_NAME}",
  "releasability": "Range42 exercise — all participant orgs",
  "description":   "Cross-team intel exchange group for all player teams and instructors.",
  "active":        true,
  "roaming":       false
}
JSON
)" 2>&1 || true)
    log "create sharing group raw response: ${resp}"
    sg_id=$(echo "${resp}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('SharingGroup', {}).get('id', ''))
" 2>/dev/null || true)
    [ -n "${sg_id}" ] || fail "Failed to create sharing group '${SG_NAME}' — empty ID returned."
    log "Sharing group '${SG_NAME}' created (id=${sg_id})."
fi

# ── Add member orgs ───────────────────────────────────────────────────────────

for org_id in "${ORG_IDS[@]}"; do
    resp=$(misp_post "/sharingGroups/addOrg/${sg_id}/${org_id}" "{}" 2>&1 || true)
    log "addOrg(sg=${sg_id}, org=${org_id}): ${resp}"
done

log "Sharing group '${SG_NAME}' provisioned with ${#ORG_IDS[@]} orgs."
