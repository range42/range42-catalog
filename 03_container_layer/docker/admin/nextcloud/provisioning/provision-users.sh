#!/usr/bin/env bash
#
# ISSUE 146
#
# provision-users.sh — creates instructor and team accounts in Nextcloud via the OCS API.
# Writes credentials to /tokens/nc-credentials.json and stamps /tokens/.provisioned.
#
# The primary admin (NC_ADMIN_USER) is auto-created by Nextcloud on first boot;
# this script records it in the credentials file but does not re-create it via OCS.
#
# Env vars consumed (all required):
#   NC_URL               — internal service URL (e.g. http://nextcloud)
#   NC_ADMIN_USER        — Nextcloud admin username
#   NC_ADMIN_PASS        — Nextcloud admin password
#   NC_TEAMS             — comma-separated team list (e.g. team-blue,team-red)
#   NC_INSTRUCTOR_ORG    — group label for instructor accounts (e.g. instructors)
#   NC_INSTRUCTOR_COUNT  — number of instructor accounts to create
#   NC_USERS_PER_TEAM    — number of regular users per team (leads are additional)
#   NC_USER_DOMAIN       — email domain (e.g. range42.local)
#
set -euo pipefail

NC_URL="${NC_URL:-http://nextcloud}"
NC_ADMIN_USER="${NC_ADMIN_USER:-admin}"
NC_ADMIN_PASS="${NC_ADMIN_PASS:-Admin1234!}"
NC_TEAMS="${NC_TEAMS:-team-blue,team-red}"
NC_INSTRUCTOR_ORG="${NC_INSTRUCTOR_ORG:-instructors}"
NC_INSTRUCTOR_COUNT="${NC_INSTRUCTOR_COUNT:-1}"
NC_USERS_PER_TEAM="${NC_USERS_PER_TEAM:-2}"
NC_USER_DOMAIN="${NC_USER_DOMAIN:-range42.local}"

TOKENS_DIR="/tokens"
CREDS_FILE="${TOKENS_DIR}/nc-credentials.json"
PROVISION_STAMP="${TOKENS_DIR}/.provisioned"

# ── 1. Wait for Nextcloud (max 180 s) ─────────────────────────────────────────
echo "[provision-users] Waiting for Nextcloud at ${NC_URL} ..."
attempts=0
until curl -sf "${NC_URL}/status.php" 2>/dev/null | grep -q '"installed":true'; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Nextcloud did not become ready after 180 s. Aborting."
    exit 1
  fi
  sleep 3
done
echo "[provision-users] Nextcloud is up."

# ── 2. Idempotency guard ──────────────────────────────────────────────────────
if [ -f "${PROVISION_STAMP}" ]; then
  echo "[provision-users] Already provisioned (stamp found). Exiting."
  exit 0
fi

mkdir -p "${TOKENS_DIR}"

# ── Helpers ───────────────────────────────────────────────────────────────────
gen_password() {
  printf 'R42!%s' "$(openssl rand -base64 16 | tr -d '/+=')" | head -c 20
}

create_user() {
  local username="$1" password="$2" email="$3" display_name="$4"
  local resp status
  resp=$(curl -sf -X POST "${NC_URL}/ocs/v1.php/cloud/users" \
    -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
    -H "OCS-APIRequest: true" \
    -H "Accept: application/json" \
    --data-urlencode "userid=${username}" \
    --data-urlencode "password=${password}" \
    --data-urlencode "email=${email}" \
    --data-urlencode "displayName=${display_name}" \
    || echo '{}')
  status=$(printf '%s' "${resp}" | jq -r '.ocs.meta.statuscode // 999' 2>/dev/null || echo 999)
  case "${status}" in
    100) echo "[provision-users]   + created: ${username}" ;;
    102) echo "[provision-users]   ~ already exists: ${username}" ;;
    *) echo "[provision-users]   ERROR: failed to create ${username} (OCS ${status}): $(printf '%s' "${resp}" | jq -r '.ocs.meta.message // "unknown"' 2>/dev/null)"; exit 1 ;;
  esac
}

add_to_admin_group() {
  local username="$1"
  curl -sf -X POST "${NC_URL}/ocs/v1.php/cloud/groups/admin/users" \
    -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
    -H "OCS-APIRequest: true" \
    -H "Accept: application/json" \
    --data-urlencode "userid=${username}" \
    >/dev/null \
    || echo "[warn] Failed to add ${username} to admin group"
}

CREDS_TMP="$(mktemp)"
printf '[\n' > "${CREDS_TMP}"
_CRED_FIRST=true

append_cred() {
  local username="$1" role="$2" team="$3" password="$4"
  "${_CRED_FIRST}" || printf ',\n' >> "${CREDS_TMP}"
  _CRED_FIRST=false
  printf '  {"username":"%s","role":"%s","team":"%s","password":"%s"}' \
    "${username}" "${role}" "${team}" "${password}" >> "${CREDS_TMP}"
}

# ── 3. Record primary admin (auto-created by Nextcloud) ───────────────────────
echo "[provision-users] Recording primary admin: ${NC_ADMIN_USER}"
append_cred "${NC_ADMIN_USER}" "admin" "" "${NC_ADMIN_PASS}"

# ── 4. Instructor accounts ────────────────────────────────────────────────────
echo "[provision-users] Creating ${NC_INSTRUCTOR_COUNT} instructor(s) ..."
i=1
while [ "${i}" -le "${NC_INSTRUCTOR_COUNT}" ]; do
  username="nc-instructor-${i}"
  password="$(gen_password)"
  email="${username}@${NC_USER_DOMAIN}"
  display_name="NC Instructor ${i}"
  create_user "${username}" "${password}" "${email}" "${display_name}"
  add_to_admin_group "${username}"
  append_cred "${username}" "instructor" "${NC_INSTRUCTOR_ORG}" "${password}"
  i=$((i + 1))
done

# ── 5. Team leads and users ───────────────────────────────────────────────────
IFS=',' read -ra TEAM_LIST <<< "${NC_TEAMS}"
for team in "${TEAM_LIST[@]}"; do
  echo "[provision-users] Creating accounts for team: ${team}"

  lead_user="nc-${team}-lead"
  lead_pass="$(gen_password)"
  lead_email="${lead_user}@${NC_USER_DOMAIN}"
  create_user "${lead_user}" "${lead_pass}" "${lead_email}" "NC Lead ${team}"
  add_to_admin_group "${lead_user}"
  append_cred "${lead_user}" "lead" "${team}" "${lead_pass}"

  j=1
  while [ "${j}" -le "${NC_USERS_PER_TEAM}" ]; do
    username="nc-${team}-user-${j}"
    password="$(gen_password)"
    email="${username}@${NC_USER_DOMAIN}"
    create_user "${username}" "${password}" "${email}" "NC User ${team} ${j}"
    append_cred "${username}" "user" "${team}" "${password}"
    j=$((j + 1))
  done
done

# ── 6. Write credentials file ─────────────────────────────────────────────────
printf '\n]\n' >> "${CREDS_TMP}"
jq --arg svc "nextcloud" --arg url "${NC_URL}" \
  '{"service":$svc,"baseurl":$url,"users":.}' \
  "${CREDS_TMP}" > "${CREDS_FILE}"
rm -f "${CREDS_TMP}"
chmod 600 "${CREDS_FILE}"
echo "[provision-users] Credentials written to ${CREDS_FILE}"

# ── 7. Idempotency stamp ──────────────────────────────────────────────────────
touch "${PROVISION_STAMP}"
echo "[provision-users] Done."
