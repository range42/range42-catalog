#!/usr/bin/env bash
# provision-sample-events.sh — imports sample MISP training events.
# Idempotent: creates missing fixtures and reconciles existing fixture UUIDs.
#
# Add more fixtures by dropping .json files into provisioning/sample-events/.
# Each file must contain a top-level "Event" object with a "uuid" field.
set -euo pipefail

MISP_URL="${MISP_URL:-https://misp}"
ADMIN_KEY_FILE="${MISP_ADMIN_KEY_FILE:-/keys/admin-authkey}"
EVENTS_DIR="${MISP_SAMPLE_EVENTS_DIR:-/provisioning/sample-events}"

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

for fixture in "${fixtures[@]}"; do
    event_uuid=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
ev = data.get('Event', data)
print(ev.get('uuid', ''))
" "${fixture}" 2>/dev/null || true)

    event_info=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
ev = data.get('Event', data)
print(ev.get('info', sys.argv[1]))
" "${fixture}" 2>/dev/null || echo "${fixture}")

    if [ -z "${event_uuid}" ]; then
        log "  WARNING: no uuid in ${fixture} — skipping"
        continue
    fi

    if misp_get "/events/view/${event_uuid}" >/dev/null 2>&1; then
        endpoint="/events/edit/${event_uuid}"
        action="Updated"
    else
        endpoint="/events/add"
        action="Created"
    fi

    resp=$(misp_post_file "${fixture}" "${endpoint}")
    created_uuid=$(echo "${resp}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('Event', {}).get('uuid', ''))
" 2>/dev/null || true)

    if [ "${created_uuid}" = "${event_uuid}" ]; then
        log "  ${action} (${created_uuid}): ${event_info}"
    else
        log "  WARNING: unexpected response for ${fixture}: ${resp:0:300}"
    fi
done

log "Sample events done."
