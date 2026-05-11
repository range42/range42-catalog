#!/usr/bin/env sh
#
# ISSUE 147
#
# Rocket.Chat provisioner: creates users and personal access tokens.
# Reads: $USERS_FILE (YAML with admins[] and users[] lists)
# Writes: /tokens/tokens.txt (username:token per line)
#

set -eu

RC_URL="${RC_URL:-http://rocketchat:3000}"
RC_ADMIN_USER="${RC_ADMIN_USER:-rc-admin}"
RC_ADMIN_PASS="${RC_ADMIN_PASS:-Admin1234!}"
USERS_FILE="${USERS_FILE:-/provisioning/users.yml}"
TOKENS_FILE="/tokens/tokens.txt"
STAMP_FILE="/tokens/.provisioned"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Wait for Rocket.Chat health (max 180s, 60 × 3s)
# ─────────────────────────────────────────────────────────────────────────────
echo "[init] Waiting for Rocket.Chat at ${RC_URL} ..."
attempts=0
max_attempts=60

until curl -sf "${RC_URL}/api/v1/info" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge "${max_attempts}" ]; then
    echo "[init] ERROR: Rocket.Chat did not become healthy after $((max_attempts * 3))s. Aborting."
    exit 1
  fi
  echo "[init] Waiting ... (${attempts}/${max_attempts})"
  sleep 3
done

echo "[init] Rocket.Chat is up."

# ─────────────────────────────────────────────────────────────────────────────
# 2. Idempotency stamp
# ─────────────────────────────────────────────────────────────────────────────
if [ -f "${STAMP_FILE}" ]; then
  echo "[init] Already provisioned (${STAMP_FILE} exists). Exiting."
  exit 0
fi

mkdir -p /tokens
: > "${TOKENS_FILE}"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Login as admin — capture auth token and user ID
# ─────────────────────────────────────────────────────────────────────────────
echo "[init] Logging in as ${RC_ADMIN_USER} ..."
auth_resp=$(curl -sf -X POST "${RC_URL}/api/v1/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "${RC_ADMIN_USER}" --arg p "${RC_ADMIN_PASS}" \
    '{"username":$u,"password":$p}')")

rc_admin_token=$(echo "${auth_resp}" | jq -r '.data.authToken')
rc_admin_id=$(echo "${auth_resp}"    | jq -r '.data.userId')

if [ -z "${rc_admin_token}" ] || [ "${rc_admin_token}" = "null" ]; then
  echo "[init] ERROR: Failed to authenticate as admin. Check RC_ADMIN_USER / RC_ADMIN_PASS."
  exit 1
fi

echo "[init] Admin auth OK (userId=${rc_admin_id})."

# ─────────────────────────────────────────────────────────────────────────────
# Helper: create a user via REST API
# Usage: create_user <username> <email> <password> <name> <roles_json>
# ─────────────────────────────────────────────────────────────────────────────
create_user() {
  _username="$1"
  _email="$2"
  _password="$3"
  _name="$4"
  _roles="$5"

  echo "[init] Creating user: ${_username} ..."
  _payload=$(jq -n \
    --arg u  "${_username}" \
    --arg e  "${_email}"    \
    --arg p  "${_password}" \
    --arg n  "${_name}"     \
    --argjson r "${_roles}" \
    '{"username":$u,"email":$e,"password":$p,"name":$n,
      "roles":$r,"joinDefaultChannels":true,
      "sendWelcomeEmail":false,"verified":true}')

  _resp=$(curl -sf -X POST "${RC_URL}/api/v1/users.create" \
    -H "X-Auth-Token: ${rc_admin_token}" \
    -H "X-User-Id: ${rc_admin_id}" \
    -H "Content-Type: application/json" \
    -d "${_payload}" 2>&1) || true

  # tolerate "Username is already in use" (idempotent)
  _success=$(echo "${_resp}" | jq -r '.success // false')
  _error=$(echo "${_resp}"   | jq -r '.error   // ""')

  if [ "${_success}" = "true" ]; then
    echo "[init] User ${_username} created."
  elif echo "${_error}" | grep -qi "already in use\|already exists\|duplicate"; then
    echo "[init] User ${_username} already exists — skipping."
  else
    echo "[init] WARNING: Unexpected response for ${_username}: ${_resp}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: generate personal access token for a user
# The user must authenticate as themselves (tokens are user-owned in RC).
# Usage: generate_token <username> <password>
# ─────────────────────────────────────────────────────────────────────────────
generate_token() {
  _username="$1"
  _password="$2"

  echo "[token] Generating PAT for ${_username} ..."

  # Login as the user
  _user_auth=$(curl -sf -X POST "${RC_URL}/api/v1/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "${_username}" --arg p "${_password}" \
      '{"username":$u,"password":$p}')") || true

  _user_token=$(echo "${_user_auth}" | jq -r '.data.authToken // ""')
  _user_id=$(echo "${_user_auth}"    | jq -r '.data.userId    // ""')

  if [ -z "${_user_token}" ] || [ "${_user_token}" = "null" ]; then
    echo "[token] WARNING: Could not log in as ${_username} — skipping token generation."
    return
  fi

  # Generate personal access token (tokenName must be unique per user)
  _token_resp=$(curl -sf -X POST "${RC_URL}/api/v1/users.generatePersonalAccessToken" \
    -H "X-Auth-Token: ${_user_token}" \
    -H "X-User-Id: ${_user_id}" \
    -H "Content-Type: application/json" \
    -d '{"tokenName":"api-token"}') || true

  _pat=$(echo "${_token_resp}" | jq -r '.token // "ERROR"')

  if [ "${_pat}" = "ERROR" ] || [ -z "${_pat}" ]; then
    # May already exist — try to list and skip gracefully
    echo "[token] WARNING: Could not generate PAT for ${_username} (may already exist)."
    return
  fi

  echo "[token] ${_username}: ${_pat}"
  echo "${_username}:${_pat}" >> "${TOKENS_FILE}"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Create admin users
# ─────────────────────────────────────────────────────────────────────────────
echo "[init] --- Processing admins ---"
admin_count=$(yq '.admins | length' "${USERS_FILE}")
i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq ".admins[${i}].username" "${USERS_FILE}")
  email=$(yq    ".admins[${i}].email"    "${USERS_FILE}")
  password=$(yq ".admins[${i}].password" "${USERS_FILE}")
  name=$(yq     ".admins[${i}].name"     "${USERS_FILE}")

  create_user "${username}" "${email}" "${password}" "${name}" '["admin"]'
  i=$((i + 1))
done

# ─────────────────────────────────────────────────────────────────────────────
# 5. Create regular users
# ─────────────────────────────────────────────────────────────────────────────
echo "[init] --- Processing users ---"
user_count=$(yq '.users | length' "${USERS_FILE}")
i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq ".users[${i}].username" "${USERS_FILE}")
  email=$(yq    ".users[${i}].email"    "${USERS_FILE}")
  password=$(yq ".users[${i}].password" "${USERS_FILE}")
  name=$(yq     ".users[${i}].name"     "${USERS_FILE}")

  create_user "${username}" "${email}" "${password}" "${name}" '["user"]'
  i=$((i + 1))
done

# ─────────────────────────────────────────────────────────────────────────────
# 6. Generate personal access tokens for ALL users (admins + regular)
# ─────────────────────────────────────────────────────────────────────────────
echo "[init] --- Generating personal access tokens ---"

# Tokens for admin users
i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq ".admins[${i}].username" "${USERS_FILE}")
  password=$(yq ".admins[${i}].password" "${USERS_FILE}")
  generate_token "${username}" "${password}"
  i=$((i + 1))
done

# Tokens for regular users
i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq ".users[${i}].username" "${USERS_FILE}")
  password=$(yq ".users[${i}].password" "${USERS_FILE}")
  generate_token "${username}" "${password}"
  i=$((i + 1))
done

# ─────────────────────────────────────────────────────────────────────────────
# 7. Print summary and mark as provisioned
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[init] ──────────────────────────────────────"
echo "[init] Provisioning complete."
echo "[init] Tokens written to: ${TOKENS_FILE}"
echo "[init] ──────────────────────────────────────"
if [ -s "${TOKENS_FILE}" ]; then
  echo "[init] Token summary:"
  while IFS= read -r line; do
    echo "        ${line}"
  done < "${TOKENS_FILE}"
fi

touch "${STAMP_FILE}"
echo "[init] Done."
