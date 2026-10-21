#!/usr/bin/env bash
# lib.sh — shared helpers sourced by every provision-*.sh script.
#
# Requires LOG_TAG to be set by the caller before sourcing.
# Reads:
#   MISP_URL       — in-network MISP endpoint (default: https://misp-nginx:8443)
#   MISP_ADMIN_KEY — site-admin API key, the same value misp-core receives as ADMIN_KEY
#   MISP_INSTRUCTOR_ORG, MISP_ORG — instructor org name resolution

MISP_URL="${MISP_URL:-https://misp-nginx:8443}"
API_WAIT_ATTEMPTS=60
API_WAIT_INTERVAL=5

log()  { echo "[${LOG_TAG}] $*" >&2; }
fail() { echo "[${LOG_TAG}] ERROR: $*" >&2; exit 1; }

# Instructor org; a blank MISP_INSTRUCTOR_ORG reuses the host org (MISP_ORG).
# shellcheck disable=SC2034  # read by the sourcing scripts
INSTRUCTOR_ORG="${MISP_INSTRUCTOR_ORG:-${MISP_ORG:-Range42}}"

ADMIN_KEY="${MISP_ADMIN_KEY:-}"
[ -n "${ADMIN_KEY}" ] || fail "MISP_ADMIN_KEY is not set"

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

misp_post_file() {
    curl -sk \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST --data "@${1}" \
        "${MISP_URL}${2}"
}

# Prints NAME upper-cased with every non-alphanumeric character replaced by "_".
env_name() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -c '[:alnum:]' '_'
}

# Prints the org-ids.env variable name for an org, e.g. "team-blue" -> MISP_ORG_ID_TEAM_BLUE.
org_env_key() {
    printf 'MISP_ORG_ID_%s' "$(env_name "$1")"
}

# Blocks until the REST API answers an authenticated request, or fails.
wait_for_api() {
    log "Waiting for the MISP API at ${MISP_URL} …"
    for _ in $(seq 1 "${API_WAIT_ATTEMPTS}"); do
        misp_get "/servers/getVersion" > /dev/null 2>&1 && { log "MISP API is up."; return 0; }
        sleep "${API_WAIT_INTERVAL}"
    done
    fail "MISP API did not answer within $((API_WAIT_ATTEMPTS * API_WAIT_INTERVAL)) s"
}
