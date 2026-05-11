#!/usr/bin/env sh
#
# ISSUE 143
#
# Bootstrap script for the Mattermost provisioner sidecar.
# Runs once after Mattermost is healthy; guarded by a stamp file for idempotency.
#
# User declarations come from USERS_FILE (default: /provisioning/users.yml).
# Admin users are created via the mattermost CLI (direct DB access via config.json).
# Personal access tokens are generated via the Mattermost REST API.
# Tokens are written to /tokens/tokens.txt and to stdout.
#
set -eu

MM_URL="${MM_URL:-http://mattermost:8065}"
MM_ADMIN_USER="${MM_ADMIN_USER:-mm-admin}"
MM_ADMIN_PASS="${MM_ADMIN_PASS:-Admin1234!}"
MM_TEAM_NAME="${MM_TEAM_NAME:-range42}"
USERS_FILE="${USERS_FILE:-/provisioning/users.yml}"
MM_CONFIG="/mattermost/config/config.json"
PROVISION_STAMP="/tokens/.provisioned"
TOKENS_FILE="/tokens/tokens.txt"

# ── 1. Wait for Mattermost HTTP (max 180 s) ─────────────────────────────────
echo "[init] Waiting for Mattermost at ${MM_URL} ..."
attempts=0
until curl -sf "${MM_URL}/api/v4/system/ping" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Mattermost did not become healthy after 180 s. Aborting."
    exit 1
  fi
  sleep 3
done
echo "[init] Mattermost is up."

# ── 2. Idempotency guard ─────────────────────────────────────────────────────
if [ -f "${PROVISION_STAMP}" ]; then
  echo "[init] Already provisioned (stamp found at ${PROVISION_STAMP}). Exiting."
  exit 0
fi

# ── 3. Admin users (mattermost CLI — direct DB, no HTTP auth needed) ─────────
admin_count=$(yq e '.admins | length' "${USERS_FILE}")
echo "[init] Creating ${admin_count} admin user(s) ..."

i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username" "${USERS_FILE}")
  email=$(yq e ".admins[${i}].email"       "${USERS_FILE}")
  password=$(yq e ".admins[${i}].password" "${USERS_FILE}")

  echo "[init]   + admin: ${username}"
  mattermost --config "${MM_CONFIG}" user create \
    --email    "${email}" \
    --username "${username}" \
    --password "${password}" \
    --system_admin 2>/dev/null \
    || echo "[warn] ${username} may already exist — skipping"

  i=$((i + 1))
done

# ── 4. Regular users (mattermost CLI) ────────────────────────────────────────
user_count=$(yq e '.users | length' "${USERS_FILE}")
echo "[init] Creating ${user_count} regular user(s) ..."

i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username" "${USERS_FILE}")
  email=$(yq e ".users[${i}].email"       "${USERS_FILE}")
  password=$(yq e ".users[${i}].password" "${USERS_FILE}")

  echo "[init]   + user: ${username}"
  mattermost --config "${MM_CONFIG}" user create \
    --email    "${email}" \
    --username "${username}" \
    --password "${password}" 2>/dev/null \
    || echo "[warn] ${username} may already exist — skipping"

  i=$((i + 1))
done

# ── 5. Login as first admin via REST API ─────────────────────────────────────
echo "[init] Logging in as ${MM_ADMIN_USER} via REST API ..."
sleep 3

auth_response=$(curl -sf -D - -X POST "${MM_URL}/api/v4/users/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "${MM_ADMIN_USER}" --arg p "${MM_ADMIN_PASS}" \
    '{"login_id":$u,"password":$p}')")

admin_token=$(printf '%s' "${auth_response}" | grep -i '^Token:' | awk '{print $2}' | tr -d '\r\n')
admin_user=$(printf '%s' "${auth_response}" | tail -1)
admin_id=$(printf '%s' "${admin_user}" | jq -r '.id')

if [ -z "${admin_token}" ] || [ "${admin_id}" = "null" ]; then
  echo "[fatal] Could not obtain admin session token. Aborting."
  exit 1
fi
echo "[init] Admin session established (id=${admin_id})."

# ── 6. Create default team ────────────────────────────────────────────────────
echo "[init] Creating team '${MM_TEAM_NAME}' ..."
team_resp=$(curl -sf -X POST "${MM_URL}/api/v4/teams" \
  -H "Authorization: Bearer ${admin_token}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "${MM_TEAM_NAME}" --arg dn "Range42" \
    '{"name":$n,"display_name":$dn,"type":"O"}')") \
  || true
team_id=$(printf '%s' "${team_resp}" | jq -r '.id // empty')
if [ -z "${team_id}" ]; then
  # Team may already exist; look it up
  team_id=$(curl -sf "${MM_URL}/api/v4/teams/name/${MM_TEAM_NAME}" \
    -H "Authorization: Bearer ${admin_token}" | jq -r '.id')
fi
echo "[init] Team id=${team_id}."

# ── 7. Add all users to team ──────────────────────────────────────────────────
add_to_team() {
  local section="${1}"
  local count j uname uid

  count=$(yq e ".${section} | length" "${USERS_FILE}")
  j=0
  while [ "${j}" -lt "${count}" ]; do
    uname=$(yq e ".${section}[${j}].username" "${USERS_FILE}")
    uid=$(curl -sf "${MM_URL}/api/v4/users/username/${uname}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id')

    echo "[init]   + team member: ${uname} (${uid})"
    curl -sf -X POST "${MM_URL}/api/v4/teams/${team_id}/members" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg uid "${uid}" --arg tid "${team_id}" \
        '{"team_id":$tid,"user_id":$uid}')" \
      >/dev/null \
      || echo "[warn] Could not add ${uname} to team — may already be a member"

    j=$((j + 1))
  done
}

echo "[init] Adding users to team '${MM_TEAM_NAME}' ..."
add_to_team admins
add_to_team users

# ── 8. Generate personal access tokens for all users ─────────────────────────
echo "[init] Generating personal access tokens ..."
: > "${TOKENS_FILE}"

generate_tokens() {
  local section="${1}"
  local count j uname uid token_val

  count=$(yq e ".${section} | length" "${USERS_FILE}")
  j=0
  while [ "${j}" -lt "${count}" ]; do
    uname=$(yq e ".${section}[${j}].username" "${USERS_FILE}")
    uid=$(curl -sf "${MM_URL}/api/v4/users/username/${uname}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id')

    token_resp=$(curl -sf -X POST "${MM_URL}/api/v4/users/${uid}/tokens" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n '{"description":"API access token"}')")
    token_val=$(printf '%s' "${token_resp}" | jq -r '.token // empty')

    if [ -n "${token_val}" ]; then
      printf '%s:%s\n' "${uname}" "${token_val}" | tee -a "${TOKENS_FILE}"
      echo "[init]   + token for ${uname}: OK"
    else
      echo "[warn] Could not create token for ${uname}"
    fi

    j=$((j + 1))
  done
}

generate_tokens admins
generate_tokens users

# ── 9. Mark as provisioned ────────────────────────────────────────────────────
touch "${PROVISION_STAMP}"
echo "[init] Provisioning complete. Tokens written to ${TOKENS_FILE}."
