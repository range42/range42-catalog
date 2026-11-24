#!/usr/bin/env bash
# provision-content.sh — enables curated MISP taxonomies and updates galaxies.
# Idempotent: enabling an already-enabled taxonomy is a no-op.
#
# Taxonomies are pre-loaded by cake Admin runUpdates during MISP first boot.
# This script only enables specific ones via the REST API.
#
# Override taxonomy namespaces by setting MISP_TAXONOMY_NAMESPACES to a
# newline-separated list of namespace strings.
set -euo pipefail

MISP_URL="https://misp"
ADMIN_KEY_FILE="/keys/admin-authkey"

log()  { echo "[provision-content] $*" >&2; }

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
        -X POST -d "${2:-}" \
        "${MISP_URL}${1}"
}

# ── Remove initial-install news thread ───────────────────────────────────────
# Belt-and-suspenders: configure-misp.sh deletes this via DB during bootstrap,
# but if any thread survived (e.g. re-created by migrations), remove it here too.

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

# ── Galaxy update ─────────────────────────────────────────────────────────────

log "Updating galaxy clusters …"
misp_post "/galaxies/update" "{}" > /dev/null || log "WARNING: galaxy update failed (non-fatal)."

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

# Ensure taxonomy definitions are imported from bundled files before enabling.
# configure-misp.sh does this via cake CLI at boot; this call is a fallback in
# case the provisioner runs against a MISP that skipped that step.
log "Triggering taxonomy import …"
misp_post "/taxonomies/update" '{}' > /dev/null \
    || log "WARNING: /taxonomies/update failed (non-fatal, continuing)."

# ── Fetch all taxonomies and enable matched ones ──────────────────────────────

log "Fetching taxonomies …"
ALL_TAX_JSON=$(misp_get "/taxonomies" || true)

# Build id→namespace map and collect IDs to enable (skip already-enabled ones)
MATCHED=$(python3 -c "
import json, sys

want = set(line.strip() for line in sys.argv[1].splitlines() if line.strip())
try:
    data = json.loads(sys.argv[2])
except Exception as e:
    print(f'parse error: {e}', file=sys.stderr)
    sys.exit(0)

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
" "${WANT_NS}" "${ALL_TAX_JSON}" 2>&1 | grep -v '^WARN:' || true)

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
