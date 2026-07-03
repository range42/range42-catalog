#!/usr/bin/env bash
#
# ISSUE 143
#
# provision-users.sh — creates the admin, instructors, team leads, and team
# users via the Mattermost REST API.
#
# Mattermost auto-promotes the first user created on a fresh database to
# system_admin (EnableOpenServer=true + EnableAPICreateAccount=true), so no
# CLI binary is required.
#
# Outputs /tokens/mm-credentials.json and stamps /tokens/.provisioned.
#
set -euo pipefail

MM_URL="${MM_URL:-http://mattermost:8065}"
MM_ADMIN_USER="${MM_ADMIN_USER:-admin}"
MM_ADMIN_PASS="${MM_ADMIN_PASS:-Admin1234!}"
MM_TEAM_NAME="${MM_TEAM_NAME:-range42}"
MM_TEAMS="${MM_TEAMS:-team-blue,team-red}"
MM_INSTRUCTOR_ORG="${MM_INSTRUCTOR_ORG:-instructors}"
MM_INSTRUCTOR_COUNT="${MM_INSTRUCTOR_COUNT:-1}"
MM_USERS_PER_TEAM="${MM_USERS_PER_TEAM:-2}"
MM_USER_DOMAIN="${MM_USER_DOMAIN:-range42.local}"
TOKENS_DIR="/tokens"
CREDS_FILE="${TOKENS_DIR}/mm-credentials.json"
PROVISION_STAMP="${TOKENS_DIR}/.provisioned"

# ── 1. Wait for Mattermost (max 180 s) ──────────────────────────────────────
echo "[provision-users] Waiting for Mattermost at ${MM_URL} ..."
attempts=0
until curl -sf "${MM_URL}/api/v4/system/ping" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Mattermost did not become healthy after 180 s. Aborting."
    exit 1
  fi
  sleep 3
done
echo "[provision-users] Mattermost is up."

# ── 2. Idempotency guard ─────────────────────────────────────────────────────
if [ -f "${PROVISION_STAMP}" ]; then
  echo "[provision-users] Already provisioned (stamp found). Exiting."
  exit 0
fi

# ── 3. Helpers ───────────────────────────────────────────────────────────────
gen_password() {
  printf 'R42!%s' "$(openssl rand -base64 16 | tr -d '/+=')" | head -c 20
}

CREDS_TMP="$(mktemp)"
printf '[\n' > "${CREDS_TMP}"
_CRED_FIRST=true

append_cred() {
  local username="${1}" password="${2}" role="${3}"
  "${_CRED_FIRST}" || printf ',\n' >> "${CREDS_TMP}"
  _CRED_FIRST=false
  jq -n --arg u "${username}" --arg p "${password}" --arg r "${role}" \
    '{"username":$u,"password":$p,"role":$r}' >> "${CREDS_TMP}"
}

# ── 4. Create admin (first user → auto system_admin on fresh DB) ─────────────
echo "[provision-users] Creating admin: ${MM_ADMIN_USER}"
curl -sf -X POST "${MM_URL}/api/v4/users" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg u "${MM_ADMIN_USER}" \
    --arg p "${MM_ADMIN_PASS}" \
    --arg e "${MM_ADMIN_USER}@${MM_USER_DOMAIN}" \
    '{"username":$u,"password":$p,"email":$e}')" >/dev/null
append_cred "${MM_ADMIN_USER}" "${MM_ADMIN_PASS}" "admin"

# ── 5. Login as admin ────────────────────────────────────────────────────────
echo "[provision-users] Obtaining admin session token ..."
attempts=0
ADMIN_TOKEN=""
until [ -n "${ADMIN_TOKEN}" ]; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 20 ]; then
    echo "[fatal] Could not log in as admin after 60 s. Aborting."
    exit 1
  fi
  auth_resp=$(curl -sf -D - -X POST "${MM_URL}/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "${MM_ADMIN_USER}" --arg p "${MM_ADMIN_PASS}" \
      '{"login_id":$u,"password":$p}')" 2>/dev/null || true)
  ADMIN_TOKEN=$(printf '%s' "${auth_resp}" | grep -i '^Token:' | awk '{print $2}' | tr -d '\r')
  [ -z "${ADMIN_TOKEN}" ] && sleep 3
done
echo "[provision-users] Admin session established."

# ── 6. Create team ───────────────────────────────────────────────────────────
echo "[provision-users] Creating team '${MM_TEAM_NAME}' ..."
team_resp=$(curl -sf -X POST "${MM_URL}/api/v4/teams" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "${MM_TEAM_NAME}" --arg dn "Range42" \
    '{"name":$n,"display_name":$dn,"type":"O"}')" || true)
TEAM_ID=$(printf '%s' "${team_resp}" | jq -r '.id // empty')
if [ -z "${TEAM_ID}" ]; then
  TEAM_ID=$(curl -sf "${MM_URL}/api/v4/teams/name/${MM_TEAM_NAME}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.id')
fi
echo "[provision-users] Team id=${TEAM_ID}."

# ── 7. Helpers: create user + add to team ────────────────────────────────────
create_user() {
  local username="${1}" password="${2}"
  curl -sf -X POST "${MM_URL}/api/v4/users" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg u "${username}" \
      --arg p "${password}" \
      --arg e "${username}@${MM_USER_DOMAIN}" \
      '{"username":$u,"password":$p,"email":$e}')" | jq -r '.id // empty'
}

add_to_team() {
  local uid="${1}"
  curl -sf -X POST "${MM_URL}/api/v4/teams/${TEAM_ID}/members" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg uid "${uid}" --arg tid "${TEAM_ID}" \
      '{"team_id":$tid,"user_id":$uid}')" >/dev/null || true
}

# Add admin to team
admin_id=$(curl -sf "${MM_URL}/api/v4/users/username/${MM_ADMIN_USER}" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.id')
add_to_team "${admin_id}"

# ── 8. Instructors ────────────────────────────────────────────────────────────
i=1
while [ "${i}" -le "${MM_INSTRUCTOR_COUNT}" ]; do
  uname="${MM_INSTRUCTOR_ORG}-$(printf '%02d' "${i}")"
  pass="$(gen_password)"
  echo "[provision-users]   + instructor: ${uname}"
  uid="$(create_user "${uname}" "${pass}")"
  add_to_team "${uid}"
  append_cred "${uname}" "${pass}" "instructor"
  i=$((i + 1))
done

# ── 9. Team leads + team users ────────────────────────────────────────────────
IFS=',' read -ra TEAM_LIST <<< "${MM_TEAMS}"
for team in "${TEAM_LIST[@]}"; do
  lead="${team}-lead"
  lead_pass="$(gen_password)"
  echo "[provision-users]   + lead: ${lead}"
  lead_uid="$(create_user "${lead}" "${lead_pass}")"
  add_to_team "${lead_uid}"
  append_cred "${lead}" "${lead_pass}" "lead"

  u=1
  while [ "${u}" -le "${MM_USERS_PER_TEAM}" ]; do
    uname="${team}-user-$(printf '%02d' "${u}")"
    pass="$(gen_password)"
    echo "[provision-users]   + user: ${uname}"
    uid="$(create_user "${uname}" "${pass}")"
    add_to_team "${uid}"
    append_cred "${uname}" "${pass}" "user"
    u=$((u + 1))
  done
done

# ── 10. Write credentials JSON ────────────────────────────────────────────────
printf '\n]\n' >> "${CREDS_TMP}"
jq --arg svc "mattermost" --arg url "${MM_URL}" \
  '{"service":$svc,"baseurl":$url,"users":.}' "${CREDS_TMP}" > "${CREDS_FILE}"
chmod 600 "${CREDS_FILE}"
rm -f "${CREDS_TMP}"

touch "${PROVISION_STAMP}"
echo "[provision-users] Done. Credentials written to ${CREDS_FILE}."
