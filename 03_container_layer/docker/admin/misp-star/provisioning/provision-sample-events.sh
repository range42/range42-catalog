#!/usr/bin/env bash
# provision-sample-events.sh — imports sample MISP training events.
# Idempotent: checks event UUID before creating; skips if already present.
# A created event must store every fixture attribute; otherwise the script
# fails, naming the fixture and the dropped attributes, and deletes the event
# when this run created it.
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
resp=$(mktemp)
trap 'rm -f "${payload}" "${resp}"' EXIT

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
# The event uuid goes into URLs below: accept only a valid UUID, in canonical form.
try:
    ev['uuid'] = str(uuid.UUID(ev['uuid']))
except ValueError:
    sys.exit('[provision-sample-events] ERROR: %s: Event uuid %r is not a valid UUID' % (src, ev['uuid']))
def rekey(node):
    if isinstance(node, dict):
        if team and isinstance(node.get('uuid'), str):
            node['uuid'] = str(uuid.uuid5(uuid.UUID(node['uuid']), team))
        for v in node.values():
            rekey(v)
    elif isinstance(node, list):
        for v in node:
            rekey(v)
try:
    rekey(ev)
except ValueError:
    sys.exit('[provision-sample-events] ERROR: %s: a nested uuid is not a valid UUID' % src)
if team:
    ev['info'] = '[%s] %s' % (team, ev.get('info', ''))
with open(dst, 'w') as f:
    json.dump(data, f)
print('%s\t%s' % (ev['uuid'], ev.get('info', src)))
" "${fixture}" "${payload}" "${TEAM}")
    event_uuid="${meta%%$'\t'*}"
    event_info="${meta#*$'\t'}"

    # Import only when MISP answers 404; any other answer (booting, auth
    # error) stops the run instead of being taken as "absent".
    code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: ${ADMIN_KEY}" \
        -H "Accept: application/json" "${MISP_URL}/events/view/${event_uuid}" || true)
    if [ "${code}" = "200" ]; then
        log "  Already exists (${event_uuid}): ${event_info}"
        continue
    elif [ "${code}" != "404" ]; then
        log "ERROR: ${fixture}: cannot check event ${event_uuid} (HTTP ${code})"
        exit 1
    fi

    misp_post_file "${payload}" "/events/add" > "${resp}"

    # /events/add drops an invalid attribute and still creates the event, so
    # compare the stored attribute count with the payload. Exit 1: incomplete
    # and created by this run (the add response carries the same event id);
    # exit 2: any other failure, nothing is deleted.
    rc=0
    misp_get "/events/view/${event_uuid}" | python3 -c "
import json, sys
src, payload, resp = sys.argv[1:4]
def attrs(e):
    out = list(e.get('Attribute') or [])
    for o in e.get('Object') or []:
        out += o.get('Attribute') or []
    return out
def event(f):
    try:
        e = json.load(f).get('Event')
        return e if isinstance(e, dict) else {}
    except Exception:
        return {}
stored_ev = event(sys.stdin)
created_ev = event(open(resp))
shipped = attrs(event(open(payload)))
stored = attrs(stored_ev)
if not stored_ev:
    print('[provision-sample-events] ERROR: %s: event not stored' % src, file=sys.stderr)
    sys.exit(2)
if len(stored) < len(shipped):
    stored_uuids = {str(a.get('uuid')).lower() for a in stored}
    named = [a for a in shipped if a.get('uuid') and str(a['uuid']).lower() not in stored_uuids]
    created = created_ev.get('id') is not None and str(created_ev.get('id')) == str(stored_ev.get('id'))
    print('[provision-sample-events] ERROR: %s: MISP stored %d of %d attributes; dropped: %s%s' % (
        src, len(stored), len(shipped),
        '; '.join('%s/%s %r (%s)' % (a.get('category'), a.get('type'), a.get('value'), a['uuid']) for a in named)
        or 'not identifiable (attributes without uuid)',
        '' if created else '; event not deleted: this run did not create it'), file=sys.stderr)
    sys.exit(1 if created else 2)
" "${fixture}" "${payload}" "${resp}" || rc=$?
    if [ "${rc}" -eq 0 ]; then
        log "  Created (${event_uuid}): ${event_info}"
        continue
    fi
    log "  /events/add response: $(head -c 300 "${resp}")"
    if [ "${rc}" -eq 1 ]; then
        # Delete the incomplete event, or the next run skips it as "Already
        # exists". MISP blocklists the uuid of a deleted event; remove that
        # entry too, or the corrected fixture could not be imported.
        for path in "/events/delete/${event_uuid}" "/event_blocklists/delete/${event_uuid}"; do
            curl -sfk -X POST -H "Authorization: ${ADMIN_KEY}" -H "Accept: application/json" \
                "${MISP_URL}${path}" >/dev/null \
                || { log "  ERROR: POST ${path} failed; remove the event and its blocklist entry by hand"; break; }
        done
    fi
    exit 1
done

log "Sample events done."
