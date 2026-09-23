#!/usr/bin/env bash
# provision-warninglists.sh — enables a curated set of MISP warning lists.
# Idempotent: enabling an already-enabled list is a no-op (MISP toggleEnable is safe to repeat).
#
# Warning lists are loaded from bundled files by configure-misp.sh (cake Admin updateWarninglists).
# This script runs after that, via provision.sh.
#
# Override the default set by setting MISP_WARNINGLIST_NAMES to a newline-separated
# list of exact warning list names (as they appear in MISP).
set -euo pipefail

MISP_URL="https://misp"
ADMIN_KEY_FILE="/keys/admin-authkey"

log()  { echo "[provision-warninglists] $*" >&2; }

ADMIN_KEY=$(tr -d '[:space:]' < "${ADMIN_KEY_FILE}" 2>/dev/null || true)
[ -n "${ADMIN_KEY}" ] || { log "ERROR: admin-authkey not found"; exit 1; }

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
        -X POST -d "${2}" \
        "${MISP_URL}${1}"
}

# ── Curated list ──────────────────────────────────────────────────────────────
# Names must match exactly what MISP stores (see GET /warninglists).
# Private/special-use ranges: avoid FPs on lab and well-known infra.
# EICAR + FP hashes: important for training — students will encounter these.
# Common domains: avoid FPs when students reference well-known sites.
# Scanner IPs: commonly seen in exercise network logs.

DEFAULT_NAMES="List of RFC 1918 CIDR blocks
List of RFC 3849 CIDR blocks
List of RFC 5735 CIDR blocks
List of RFC 6598 CIDR blocks
List of RFC 5771 multicast CIDR blocks
List of IPv6 link local blocks
List of RFC 6761 Special-Use Domain Names
List of hashes for EICAR test virus
List of known hashes for empty files
Hashes that are often included in IOC lists but are false positives.
Top 1000 website from Alexa
Top 10K most-used sites from Tranco
Shodan IP Ranges Used for Scanning
Rapid7 IP Ranges Used for Scanning"

WANT_NAMES="${MISP_WARNINGLIST_NAMES:-${DEFAULT_NAMES}}"

# ── Resolve names → IDs ───────────────────────────────────────────────────────

log "Fetching warning lists …"
ALL_LISTS_JSON=$(misp_get "/warninglists" || true)

MATCHED_IDS=$(python3 -c "
import json, sys

want = set(line.strip() for line in sys.argv[1].splitlines() if line.strip())
try:
    data = json.loads(sys.argv[2])
except Exception:
    sys.exit(0)

items = data.get('Warninglists', data) if isinstance(data, dict) else data
found = set()
for item in items:
    wl = item.get('Warninglist', item)
    name = wl.get('name', '')
    if name in want and not wl.get('enabled', False):
        print(wl['id'])
        found.add(name)

for m in sorted(want - found):
    print(f'WARN: no match for \"{m}\"', file=sys.stderr)
" "${WANT_NAMES}" "${ALL_LISTS_JSON}" 2>&1 | grep -v '^WARN:' || true)

WARNINGS=$(python3 -c "
import json, sys

want = set(line.strip() for line in sys.argv[1].splitlines() if line.strip())
try:
    data = json.loads(sys.argv[2])
except Exception:
    sys.exit(0)

items = data.get('Warninglists', data) if isinstance(data, dict) else data
found = set(item.get('Warninglist', item).get('name', '') for item in items
            if item.get('Warninglist', item).get('name', '') in want)
for m in sorted(want - found):
    print(m)
" "${WANT_NAMES}" "${ALL_LISTS_JSON}" 2>/dev/null || true)

[ -n "${WARNINGS}" ] && log "WARNING: no match for: $(echo "${WARNINGS}" | tr '\n' ',')"

if [ -z "${MATCHED_IDS}" ]; then
    log "All target warning lists already enabled (or none matched) — nothing to do."
    exit 0
fi

# ── Enable matched lists ──────────────────────────────────────────────────────

for id in ${MATCHED_IDS}; do
    resp=$(misp_post "/warninglists/toggleEnable" "{\"id\":${id},\"value\":\"true\"}" || true)
    msg=$(echo "${resp}" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success', json.dumps(d)))" 2>/dev/null || echo "${resp}")
    log "  id=${id}: ${msg}"
done

log "Warning lists done."
