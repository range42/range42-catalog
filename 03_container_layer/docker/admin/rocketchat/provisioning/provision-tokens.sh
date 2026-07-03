#!/usr/bin/env bash
# provision-tokens.sh — generates a Personal Access Token for every provisioned user.
# Called by provision.sh after provision-users.sh completes.
#
# Reads:
#   /tokens/rc-credentials.json  — written by provision-users.sh
#   RC_URL                       — RC internal URL (default: http://rocketchat:3000)
#
# Writes:
#   /tokens/tokens.txt  — one "username:PAT" line per user, chmod 600
set -euo pipefail

RC_URL="${RC_URL:-http://rocketchat:3000}"

CREDS_FILE="/tokens/rc-credentials.json"
TOKENS_FILE="/tokens/tokens.txt"

log()  { echo "[provision-tokens] $*" >&2; }
fail() { echo "[provision-tokens] ERROR: $*" >&2; exit 1; }

[ -f "${CREDS_FILE}" ] || fail "${CREDS_FILE} not found — did provision-users.sh run?"

: > "${TOKENS_FILE}"
chmod 600 "${TOKENS_FILE}"

# ── Generate a PAT for one user ───────────────────────────────────────────────

generate_token() {
    local username="$1" password="$2"

    # Login as the user to get their own auth token
    local auth_resp login_token user_id
    auth_resp=$(curl -sf -X POST "${RC_URL}/api/v1/login" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg u "${username}" --arg p "${password}" '{"username":$u,"password":$p}')") || {
        log "WARNING: Login failed for ${username} — skipping token."
        return 0
    }

    login_token=$(echo "${auth_resp}" | jq -r '.data.authToken // empty')
    user_id=$(echo "${auth_resp}"     | jq -r '.data.userId    // empty')

    if [ -z "${login_token}" ] || [ -z "${user_id}" ]; then
        log "WARNING: Could not parse auth response for ${username} — skipping."
        return 0
    fi

    # Generate a named Personal Access Token
    local token_resp pat
    token_resp=$(curl -sf -X POST "${RC_URL}/api/v1/users.generatePersonalAccessToken" \
        -H "X-Auth-Token: ${login_token}" \
        -H "X-User-Id: ${user_id}" \
        -H "Content-Type: application/json" \
        -d '{"tokenName":"api-token"}') || {
        log "WARNING: PAT generation failed for ${username} — skipping."
        return 0
    }

    pat=$(echo "${token_resp}" | jq -r '.token // empty')
    if [ -z "${pat}" ]; then
        log "WARNING: Empty PAT for ${username}: ${token_resp}"
        return 0
    fi

    printf '%s:%s\n' "${username}" "${pat}" >> "${TOKENS_FILE}"
    log "Token generated for ${username}."
}

# ── Iterate over all users in rc-credentials.json ────────────────────────────

log "Generating Personal Access Tokens …"

while IFS= read -r entry; do
    username=$(echo "${entry}" | jq -r '.username')
    password=$(echo "${entry}" | jq -r '.password')
    generate_token "${username}" "${password}"
done < <(jq -c '.users[]' "${CREDS_FILE}")

log "Tokens written to ${TOKENS_FILE}"
