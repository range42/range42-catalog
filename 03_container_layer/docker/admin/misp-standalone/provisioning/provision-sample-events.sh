#!/usr/bin/env bash
# provision-sample-events.sh — imports sample MISP training events.
# Idempotent: checks event UUID before creating; skips if already present.
#
# Add more fixtures by dropping .json files into provisioning/sample-events/.
# Each file must contain a top-level "Event" object with a "uuid" field.
set -euo pipefail

LOG_TAG="provision-sample-events"
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
EVENTS_DIR="/provisioning/sample-events"

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
        log "  Already exists (${event_uuid}): ${event_info}"
        continue
    fi

    resp=$(misp_post_file "${fixture}" "/events/add")
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
