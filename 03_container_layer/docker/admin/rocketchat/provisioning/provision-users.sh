#!/usr/bin/env bash
# provision-users.sh — creates all Rocket.Chat user accounts.
# Called by provision.sh after the rocketchat service is healthy.
#
# Reads env vars:
#   RC_URL              — RC internal URL       (default: http://rocketchat:3000)
#   RC_ADMIN_USER       — bootstrap admin name  (default: rc-admin)
#   RC_ADMIN_PASS       — bootstrap admin pass  (default: Admin1234!)
#   RC_TEAMS            — comma-separated team names (default: team-blue,team-red)
#   RC_INSTRUCTOR_ORG   — instructor prefix     (default: instructors)
#   RC_INSTRUCTOR_COUNT — instructor accounts   (default: 1)
#   RC_USERS_PER_TEAM   — regular users/team    (default: 2)
#   RC_USER_DOMAIN      — email domain          (default: range42.local)
#
# Writes:
#   /tokens/rc-credentials.json  — structured credentials for all accounts
#   /tokens/.provisioned         — idempotency stamp
set -euo pipefail

RC_URL="${RC_URL:-http://rocketchat:3000}"
RC_ADMIN_USER="${RC_ADMIN_USER:-rc-admin}"
RC_ADMIN_PASS="${RC_ADMIN_PASS:-Admin1234!}"
RC_TEAMS="${RC_TEAMS:-team-blue,team-red}"
RC_INSTRUCTOR_ORG="${RC_INSTRUCTOR_ORG:-instructors}"
RC_INSTRUCTOR_COUNT="${RC_INSTRUCTOR_COUNT:-1}"
RC_USERS_PER_TEAM="${RC_USERS_PER_TEAM:-2}"
RC_USER_DOMAIN="${RC_USER_DOMAIN:-range42.local}"

CREDS_FILE="/tokens/rc-credentials.json"
CREDS_TMP="/tokens/.creds.tmp"
STAMP_FILE="/tokens/.provisioned"

log()  { echo "[provision-users] $*" >&2; }
fail() { echo "[provision-users] ERROR: $*" >&2; exit 1; }

# ── Idempotency guard ─────────────────────────────────────────────────────────

if [ -f "${STAMP_FILE}" ]; then
    log "Already provisioned (${STAMP_FILE} exists). Exiting."
    exit 0
fi

mkdir -p /tokens

# ── Wait for Rocket.Chat API ──────────────────────────────────────────────────

log "Waiting for Rocket.Chat at ${RC_URL} …"
attempts=0
until curl -sf "${RC_URL}/api/info" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "${attempts}" -ge 60 ] && fail "Rocket.Chat did not respond after 180 s."
    log "Waiting … (${attempts}/60)"
    sleep 3
done
log "Rocket.Chat is up."

# ── Login as bootstrap admin ──────────────────────────────────────────────────

auth_resp=$(curl -sf -X POST "${RC_URL}/api/v1/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "${RC_ADMIN_USER}" --arg p "${RC_ADMIN_PASS}" '{"username":$u,"password":$p}')")

ADMIN_TOKEN=$(echo "${auth_resp}" | jq -r '.data.authToken')
ADMIN_ID=$(echo "${auth_resp}"    | jq -r '.data.userId')

[ -n "${ADMIN_TOKEN}" ] && [ "${ADMIN_TOKEN}" != "null" ] || \
    fail "Failed to authenticate as ${RC_ADMIN_USER}. Check RC_ADMIN_USER / RC_ADMIN_PASS."

log "Admin auth OK (userId=${ADMIN_ID})."

# ── Password generator ────────────────────────────────────────────────────────
# Produces a 20-char password satisfying complexity requirements (R42! prefix).

gen_password() {
    printf 'R42!%s' "$(openssl rand -base64 16 | tr -d '/+=')" | head -c 20
}

# ── REST: create a user ───────────────────────────────────────────────────────

create_user() {
    local username="$1" email="$2" password="$3" name="$4" roles="$5"
    local payload resp success error
    payload=$(jq -n \
        --arg u "${username}" --arg e "${email}" \
        --arg p "${password}" --arg n "${name}" \
        --argjson r "${roles}" \
        '{"username":$u,"email":$e,"password":$p,"name":$n,
          "roles":$r,"joinDefaultChannels":true,
          "sendWelcomeEmail":false,"verified":true}')
    resp=$(curl -sf -X POST "${RC_URL}/api/v1/users.create" \
        -H "X-Auth-Token: ${ADMIN_TOKEN}" \
        -H "X-User-Id: ${ADMIN_ID}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>&1) || true
    success=$(echo "${resp}" | jq -r '.success // false')
    error=$(echo "${resp}"   | jq -r '.error   // ""')
    if [ "${success}" = "true" ]; then
        log "User ${username} created."
    elif echo "${error}" | grep -qi "already in use\|already exists\|duplicate"; then
        log "User ${username} already exists — skipping."
    else
        log "WARNING: Unexpected response for ${username}: ${resp}"
    fi
}

# ── Credentials accumulator ───────────────────────────────────────────────────

printf '[\n' > "${CREDS_TMP}"
_CRED_FIRST=true

append_cred() {
    local username="$1" role="$2" team="$3" password="$4"
    "${_CRED_FIRST}" || printf ',\n' >> "${CREDS_TMP}"
    _CRED_FIRST=false
    jq -n \
        --arg u "${username}" --arg r "${role}" \
        --arg t "${team}"     --arg p "${password}" \
        '{"username":$u,"role":$r,"team":$t,"password":$p}' >> "${CREDS_TMP}"
}

# ── Primary admin ─────────────────────────────────────────────────────────────

log "Recording primary admin ${RC_ADMIN_USER} …"
append_cred "${RC_ADMIN_USER}" "admin" "admin" "${RC_ADMIN_PASS}"

# ── Instructors ───────────────────────────────────────────────────────────────

log "Creating ${RC_INSTRUCTOR_COUNT} instructor account(s) …"
for i in $(seq 1 "${RC_INSTRUCTOR_COUNT}"); do
    suffix=$([ "${RC_INSTRUCTOR_COUNT}" -eq 1 ] && echo "" || echo "${i}")
    username="${RC_INSTRUCTOR_ORG}${suffix}"
    email="${username}@${RC_USER_DOMAIN}"
    password=$(gen_password)
    name="Instructor${suffix:+ ${suffix}}"
    create_user "${username}" "${email}" "${password}" "${name}" '["admin"]'
    append_cred "${username}" "admin" "${RC_INSTRUCTOR_ORG}" "${password}"
done

# ── Team users ────────────────────────────────────────────────────────────────

IFS=',' read -ra TEAM_LIST <<< "${RC_TEAMS}"
for raw_team in "${TEAM_LIST[@]}"; do
    team=$(echo "${raw_team}" | tr -d '[:space:]')
    [ -z "${team}" ] && continue

    log "Creating team '${team}' (1 lead + ${RC_USERS_PER_TEAM} user(s)) …"

    # Team lead — admin role so they can manage their own team channel
    lead_pass=$(gen_password)
    create_user "${team}-lead" "${team}-lead@${RC_USER_DOMAIN}" "${lead_pass}" "${team} Lead" '["admin"]'
    append_cred "${team}-lead" "admin" "${team}" "${lead_pass}"

    # Regular team members
    for i in $(seq 1 "${RC_USERS_PER_TEAM}"); do
        user_pass=$(gen_password)
        create_user "${team}-user${i}" "${team}-user${i}@${RC_USER_DOMAIN}" \
            "${user_pass}" "${team} User ${i}" '["user"]'
        append_cred "${team}-user${i}" "user" "${team}" "${user_pass}"
    done
done

# ── Write rc-credentials.json ─────────────────────────────────────────────────

printf '\n]\n' >> "${CREDS_TMP}"
jq \
    --arg svc "rocketchat" \
    --arg url "${RC_BASE_URL:-http://localhost:3000}" \
    '{"service":$svc,"baseurl":$url,"users":.}' \
    "${CREDS_TMP}" > "${CREDS_FILE}"
chmod 600 "${CREDS_FILE}"
rm -f "${CREDS_TMP}"

log "Credentials written to ${CREDS_FILE}"
touch "${STAMP_FILE}"
log "User provisioning complete."
