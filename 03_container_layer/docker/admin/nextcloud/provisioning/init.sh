#!/bin/sh
#
# ISSUE 146
#
# Bootstrap script for the Nextcloud provisioner sidecar.
# Runs once after Nextcloud is healthy; guarded by a stamp file for idempotency.
#
# User declarations come from USERS_FILE (default: /provisioning/users.yml).
# Admin users are created via the OCS API and added to the admin group.
# Regular users are created via the OCS API.
# App passwords are generated for every user and written to /tokens/tokens.txt.
#
set -eu

NC_URL="${NC_URL:-http://nextcloud}"
NC_ADMIN_USER="${NC_ADMIN_USER:-nc-admin}"
NC_ADMIN_PASS="${NC_ADMIN_PASS:-Admin1234!}"
USERS_FILE="${USERS_FILE:-/provisioning/users.yml}"
TOKENS_DIR="/tokens"
TOKENS_FILE="${TOKENS_DIR}/tokens.txt"
PROVISION_STAMP="${TOKENS_DIR}/.provisioned"

# ── 1. Wait for Nextcloud HTTP (max 180 s) ──────────────────────────────────
echo "[init] Waiting for Nextcloud at ${NC_URL} ..."
attempts=0
until curl -sf "${NC_URL}/status.php" 2>/dev/null | grep -q '"installed":true'; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Nextcloud did not become healthy after 180 s. Aborting."
    exit 1
  fi
  sleep 3
done
echo "[init] Nextcloud is up."

# ── 2. Idempotency guard ────────────────────────────────────────────────────
if [ -f "${PROVISION_STAMP}" ]; then
  echo "[init] Already provisioned (stamp found at ${PROVISION_STAMP}). Exiting."
  exit 0
fi

mkdir -p "${TOKENS_DIR}"
: > "${TOKENS_FILE}"

# ── Helper: create a user via OCS API ──────────────────────────────────────
create_user() {
  local username="${1}"
  local password="${2}"
  local email="${3}"
  local display_name="${4}"

  resp=$(curl -sf -X POST "${NC_URL}/ocs/v1.php/cloud/users" \
    -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
    -H "OCS-APIRequest: true" \
    -H "Accept: application/json" \
    --data-urlencode "userid=${username}" \
    --data-urlencode "password=${password}" \
    --data-urlencode "email=${email}" \
    --data-urlencode "displayName=${display_name}" \
    || echo '{}')
  status=$(echo "${resp}" | jq -r '.ocs.meta.statuscode // 999' 2>/dev/null || echo 999)
  case "${status}" in
    100) echo "[init]   + user created: ${username}" ;;
    102) echo "[warn]   ${username} already exists — skipping" ;;
    *) echo "[error]  Failed to create ${username} (OCS status ${status}): $(echo "${resp}" | jq -r '.ocs.meta.message // "unknown error"' 2>/dev/null)"; exit 1 ;;
  esac
}

# ── Helper: add a user to the admin group ──────────────────────────────────
add_to_admin_group() {
  local username="${1}"

  echo "[init]   + adding ${username} to admin group"
  curl -sf -X POST "${NC_URL}/ocs/v1.php/cloud/groups/admin/users" \
    -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
    -H "OCS-APIRequest: true" \
    -H "Accept: application/json" \
    --data-urlencode "userid=${username}" \
    >/dev/null \
    || echo "[warn] Failed to add ${username} to admin group"
}

# ── Helper: generate an app password for a user ────────────────────────────
generate_app_password() {
  local username="${1}"
  local password="${2}"

  echo "[init]   + generating app password for ${username}"
  app_pass_resp=$(curl -sf -X POST "${NC_URL}/ocs/v2.php/core/apppassword" \
    -u "${username}:${password}" \
    -H "OCS-APIRequest: true" \
    -H "Accept: application/json" \
    || echo '{}')

  app_pass=$(printf '%s' "${app_pass_resp}" | jq -r '.ocs.data.apppassword // "ERROR"' 2>/dev/null || echo "ERROR")

  if [ "${app_pass}" = "ERROR" ] || [ -z "${app_pass}" ]; then
    echo "[warn] Could not generate app password for ${username}"
    app_pass="ERROR"
  fi

  printf '%s: %s\n' "${username}" "${app_pass}" >> "${TOKENS_FILE}"
  printf '[token] %s: %s\n' "${username}" "${app_pass}"
}

# ── 3. Admin users ──────────────────────────────────────────────────────────
admin_count=$(yq e '.admins | length' "${USERS_FILE}")
echo "[init] Creating ${admin_count} admin user(s) ..."

i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username"     "${USERS_FILE}")
  email=$(yq e ".admins[${i}].email"           "${USERS_FILE}")
  password=$(yq e ".admins[${i}].password"     "${USERS_FILE}")
  display_name=$(yq e ".admins[${i}].display_name // \"\"" "${USERS_FILE}")

  create_user "${username}" "${password}" "${email}" "${display_name}"
  add_to_admin_group "${username}"

  i=$((i + 1))
done

# ── 4. Regular users ────────────────────────────────────────────────────────
user_count=$(yq e '.users | length' "${USERS_FILE}")
echo "[init] Creating ${user_count} regular user(s) ..."

i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username"     "${USERS_FILE}")
  email=$(yq e ".users[${i}].email"           "${USERS_FILE}")
  password=$(yq e ".users[${i}].password"     "${USERS_FILE}")
  display_name=$(yq e ".users[${i}].display_name // \"\"" "${USERS_FILE}")

  create_user "${username}" "${password}" "${email}" "${display_name}"

  i=$((i + 1))
done

# ── 4b. Wait for user accounts to be ready before generating app passwords ──
echo "[init] Waiting for user accounts to be ready ..."
sleep 2

# ── 4c. Generate app passwords for all users ────────────────────────────────
echo "[init] Generating app passwords ..."

i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username" "${USERS_FILE}")
  password=$(yq e ".admins[${i}].password" "${USERS_FILE}")
  generate_app_password "${username}" "${password}"
  i=$((i + 1))
done

i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username" "${USERS_FILE}")
  password=$(yq e ".users[${i}].password" "${USERS_FILE}")
  generate_app_password "${username}" "${password}"
  i=$((i + 1))
done

# ── 5. Mark as provisioned ──────────────────────────────────────────────────
touch "${PROVISION_STAMP}"
echo "[init] Provisioning complete. App passwords written to ${TOKENS_FILE}."
