#!/usr/bin/env bash
# provision-warninglists.sh — enables a curated set of MISP warning lists.
# Idempotent: enabling an already-enabled list is a no-op (MISP toggleEnable is safe to repeat).
#
# misp-core loads warning lists from bundled files on every boot; this script only enables them.
#
# Override the default set by setting MISP_WARNINGLIST_NAMES to a newline-separated
# list of exact warning list names (as they appear in MISP).
set -euo pipefail

LOG_TAG="provision-warninglists"
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

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
# Prints "ID <id>" for each wanted list not yet enabled and "MISSING <name>" for
# each wanted name MISP does not know; JSON arrives on stdin.
RESOLVED=$(misp_get "/warninglists" | python3 -c "
import json, sys

want = set(line.strip() for line in sys.argv[1].splitlines() if line.strip())
data = json.load(sys.stdin)

items = data.get('Warninglists', data) if isinstance(data, dict) else data
found = set()
for item in items:
    wl = item.get('Warninglist', item)
    name = wl.get('name', '')
    if name in want:
        found.add(name)
        if not wl.get('enabled', False):
            print(f\"ID {wl['id']}\")

for m in sorted(want - found):
    print(f'MISSING {m}')
" "${WANT_NAMES}") || fail "could not read /warninglists"

MATCHED_IDS=$(sed -n 's/^ID //p' <<< "${RESOLVED}")
MISSING=$(sed -n 's/^MISSING //p' <<< "${RESOLVED}")
[ -n "${MISSING}" ] && log "WARNING: no match for: $(paste -sd, - <<< "${MISSING}")"

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
