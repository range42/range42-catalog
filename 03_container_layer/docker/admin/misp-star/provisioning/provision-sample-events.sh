#!/usr/bin/env bash
# provision-sample-events.sh — imports sample MISP training events.
# Idempotent: checks event UUID before creating; skips if already present.
#
# Add more fixtures by dropping .json files into provisioning/sample-events/.
# Each file must contain a top-level "Event" object with a "uuid" field;
# software.configure.misp_sync reads .Event.uuid too. A file without it stops
# the provisioner with an error naming the file.
set -euo pipefail

MISP_URL="https://misp"
ADMIN_KEY_FILE="/keys/admin-authkey"
EVENTS_DIR="/provisioning/sample-events"

log() { echo "[provision-sample-events] $*" >&2; }

ADMIN_KEY=$(tr -d '[:space:]' < "${ADMIN_KEY_FILE}" 2>/dev/null || true)
[ -n "${ADMIN_KEY}" ] || { log "ERROR: admin-authkey not found"; exit 1; }

misp_get() {
    curl -sfk \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Accept: application/json" \
        "${MISP_URL}${1}"
}

misp_post_file() {
    curl -sk \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST \
        --data "@${1}" \
        "${MISP_URL}${2}"
}

shopt -s nullglob
fixtures=("${EVENTS_DIR}"/*.json)

if [ ${#fixtures[@]} -eq 0 ]; then
    log "No fixture files found in ${EVENTS_DIR} — nothing to do."
    exit 0
fi

# Spoke mode: each team gets its own copy of every fixture. Every uuid in the
# event becomes uuid5(<fixture uuid>, MISP_ORG) and the info gets a "[team]"
# prefix, so the team copies do not collide with each other or with the hub
# copy once synced. software.configure.misp_sync derives the same UUIDs to
# bind the copies to the team sharing group and publish them.
TEAM=""
[ "${MISP_STAR_MODE:-hub}" = "spoke" ] && TEAM="${MISP_ORG:?MISP_ORG is required in spoke mode}"
payload=$(mktemp)
trap 'rm -f "${payload}"' EXIT

for fixture in "${fixtures[@]}"; do
    # Writes the payload to send and prints "<event uuid>\t<info>".
    meta=$(python3 -c "
import json, sys, uuid
src, dst, team = sys.argv[1:4]
with open(src) as f:
    data = json.load(f)
ev = data.get('Event') if isinstance(data, dict) else None
if not isinstance(ev, dict) or not isinstance(ev.get('uuid'), str) or not ev['uuid']:
    sys.exit('[provision-sample-events] ERROR: %s: no top-level \"Event\" object with a \"uuid\" (bare event JSON is not accepted)' % src)
def rekey(node):
    if isinstance(node, dict):
        if team and isinstance(node.get('uuid'), str):
            node['uuid'] = str(uuid.uuid5(uuid.UUID(node['uuid']), team))
        for v in node.values():
            rekey(v)
    elif isinstance(node, list):
        for v in node:
            rekey(v)
rekey(ev)
if team:
    ev['info'] = '[%s] %s' % (team, ev.get('info', ''))
with open(dst, 'w') as f:
    json.dump(data, f)
print('%s\t%s' % (ev['uuid'], ev.get('info', src)))
" "${fixture}" "${payload}" "${TEAM}")
    event_uuid="${meta%%$'\t'*}"
    event_info="${meta#*$'\t'}"

    if misp_get "/events/view/${event_uuid}" >/dev/null 2>&1; then
        log "  Already exists (${event_uuid}): ${event_info}"
        continue
    fi

    resp=$(misp_post_file "${payload}" "/events/add")
    created_uuid=$(echo "${resp}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('Event', {}).get('uuid', ''))
" 2>/dev/null || true)

    if [ -n "${created_uuid}" ]; then
        log "  Created (${created_uuid}): ${event_info}"
    else
        log "  WARNING: unexpected response for ${fixture}: ${resp:0:300}"
    fi
done

log "Sample events done."
