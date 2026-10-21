#!/usr/bin/env bash
# provision-content.sh — enables curated MISP taxonomies and removes the install news thread.
# Idempotent: enabling an already-enabled taxonomy is a no-op.
#
# misp-core loads galaxies and taxonomies from bundled files on every boot.
# This script only enables specific ones via the REST API.
#
# Override taxonomy namespaces by setting MISP_TAXONOMY_NAMESPACES to a
# newline-separated list of namespace strings.
set -euo pipefail

LOG_TAG="provision-content"
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

# ── Remove initial-install news thread ───────────────────────────────────────
# MISP seeds an "Initial Install" thread that shows as news after every login.

log "Removing initial-install news threads …"
THREADS_JSON=$(misp_get "/threads/index.json" 2>/dev/null || true)
if [ -n "${THREADS_JSON}" ] && echo "${THREADS_JSON}" | grep -qi '"Thread"'; then
    THREAD_IDS=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    items = data if isinstance(data, list) else data.get('response', data.get('threads', []))
    for item in items:
        t = item.get('Thread', item)
        if 'Initial' in str(t.get('title', '')):
            print(t['id'])
except Exception:
    pass
" "${THREADS_JSON}" 2>/dev/null || true)
    for tid in ${THREAD_IDS}; do
        misp_post "/threads/delete/${tid}" '{}' > /dev/null \
            && log "  Deleted thread id=${tid}" \
            || log "  WARNING: could not delete thread id=${tid} (non-fatal)"
    done
fi

# ── Curated taxonomy namespaces ───────────────────────────────────────────────
# tlp            — Traffic Light Protocol: essential for sharing classification
# kill-chain     — Lockheed Martin Kill Chain: attack phase annotation
# misp           — MISP internal workflow tags
# admiralty-scale — Intelligence source reliability (Admiralty Scale)
# cti            — Cyber Threat Intelligence taxonomy
# rsit           — Reference Security Incident Taxonomy
# workflow       — Event/attribute workflow states

DEFAULT_NAMESPACES="tlp
kill-chain
misp
admiralty-scale
cti
rsit
workflow"

WANT_NS="${MISP_TAXONOMY_NAMESPACES:-${DEFAULT_NAMESPACES}}"

# ── Fetch all taxonomies and enable matched ones ──────────────────────────────

log "Fetching taxonomies …"
# Prints id:namespace:enabled for each wanted taxonomy; JSON arrives on stdin.
MATCHED=$(misp_get "/taxonomies" | python3 -c "
import json, sys

want = set(line.strip() for line in sys.argv[1].splitlines() if line.strip())
data = json.load(sys.stdin)

# MISP wraps the list in various keys depending on version; try all known shapes.
if isinstance(data, list):
    items = data
elif isinstance(data, dict):
    items = (data.get('Taxonomies')
             or data.get('response')
             or next((v for v in data.values() if isinstance(v, list)), []))
else:
    items = []

found = set()
for item in items:
    t = item.get('Taxonomy', item)
    ns = t.get('namespace', '')
    if ns in want:
        enabled = t.get('enabled', False)
        print(f\"{t['id']}:{ns}:{'1' if enabled else '0'}\")
        found.add(ns)

for m in sorted(want - found):
    print(f'WARN: namespace not found: {m}', file=sys.stderr)
" "${WANT_NS}") || fail "could not read /taxonomies"

if [ -z "${MATCHED}" ]; then
    log "WARNING: no matching taxonomies found — check that /taxonomies returned data."
fi

for entry in ${MATCHED}; do
    id="${entry%%:*}"
    rest="${entry#*:}"
    ns="${rest%%:*}"
    already="${rest##*:}"
    if [ "${already}" = "1" ]; then
        log "  Already enabled: ${ns} (id=${id}) — skipping."
    else
        misp_post "/taxonomies/enable/${id}" > /dev/null || true
        log "  Enabled taxonomy: ${ns} (id=${id})"
    fi
done

log "Content provisioning done."
