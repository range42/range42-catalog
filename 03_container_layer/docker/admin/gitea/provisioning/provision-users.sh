#!/usr/bin/env bash
#
# ISSUE 141
#
# provision-users.sh — creates the admin, instructors, team leads, and team
# users for the Gitea instance.
#
# Admin is created via the Gitea CLI (direct DB access — no HTTP auth needed).
# Regular users are created via POST /api/v1/admin/users (admin basic auth).
#
# Outputs /tokens/gitea-credentials.json and stamps /tokens/.provisioned.
#
set -euo pipefail

GITEA_URL="${GITEA_URL:-http://gitea:3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-Admin1234!}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@range42.local}"
GITEA_TEAMS="${GITEA_TEAMS:-team-blue,team-red}"
GITEA_INSTRUCTOR_COUNT="${GITEA_INSTRUCTOR_COUNT:-1}"
GITEA_USERS_PER_TEAM="${GITEA_USERS_PER_TEAM:-2}"
GITEA_USER_DOMAIN="${GITEA_USER_DOMAIN:-range42.local}"
GITEA_CONFIG="/data/gitea/conf/app.ini"
TOKENS_DIR="/tokens"
CREDS_FILE="${TOKENS_DIR}/gitea-credentials.json"
PROVISION_STAMP="${TOKENS_DIR}/.provisioned"

# ── 1. Wait for Gitea HTTP (max 180 s) ──────────────────────────────────────
echo "[provision-users] Waiting for Gitea at ${GITEA_URL} ..."
attempts=0
until curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Gitea did not become healthy after 180 s. Aborting."
    exit 1
  fi
  sleep 3
done
echo "[provision-users] Gitea is up."

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

# ── 4. Create admin via CLI (direct DB — no HTTP auth needed) ────────────────
echo "[provision-users] Creating admin: ${GITEA_ADMIN_USER}"
cli_out=$(gitea admin user create \
  --config "${GITEA_CONFIG}" \
  --admin \
  --username "${GITEA_ADMIN_USER}" \
  --password "${GITEA_ADMIN_PASS}" \
  --email    "${GITEA_ADMIN_EMAIL}" \
  --must-change-password=false 2>&1) || {
  case "${cli_out}" in
    *"user already exists"*|*"name already exists"*)
      echo "[warn] ${GITEA_ADMIN_USER} already exists — skipping" ;;
    *)
      echo "[error] Failed to create admin: ${cli_out}"; exit 1 ;;
  esac
}
append_cred "${GITEA_ADMIN_USER}" "${GITEA_ADMIN_PASS}" "admin"

# ── 5. Create regular user via REST API (admin basic auth) ───────────────────
create_user() {
  local username="${1}" password="${2}"
  curl -sf -X POST "${GITEA_URL}/api/v1/admin/users" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg u "${username}" \
      --arg p "${password}" \
      --arg e "${username}@${GITEA_USER_DOMAIN}" \
      '{"email":$e,"login_name":$u,"must_change_password":false,"password":$p,"send_notify":false,"source_id":0,"username":$u}')" \
    >/dev/null || echo "[warn] ${username} may already exist — skipping"
}

# ── 6. Instructors ───────────────────────────────────────────────────────────
i=1
while [ "${i}" -le "${GITEA_INSTRUCTOR_COUNT}" ]; do
  uname="instructor-$(printf '%02d' "${i}")"
  pass="$(gen_password)"
  echo "[provision-users]   + instructor: ${uname}"
  create_user "${uname}" "${pass}"
  append_cred "${uname}" "${pass}" "instructor"
  i=$((i + 1))
done

# ── 7. Team leads + team users ───────────────────────────────────────────────
IFS=',' read -ra TEAM_LIST <<< "${GITEA_TEAMS}"
for team in "${TEAM_LIST[@]}"; do
  lead="${team}-lead"
  lead_pass="$(gen_password)"
  echo "[provision-users]   + lead: ${lead}"
  create_user "${lead}" "${lead_pass}"
  append_cred "${lead}" "${lead_pass}" "lead"

  u=1
  while [ "${u}" -le "${GITEA_USERS_PER_TEAM}" ]; do
    uname="${team}-user-$(printf '%02d' "${u}")"
    pass="$(gen_password)"
    echo "[provision-users]   + user: ${uname}"
    create_user "${uname}" "${pass}"
    append_cred "${uname}" "${pass}" "user"
    u=$((u + 1))
  done
done

# ── 8. Write credentials JSON ────────────────────────────────────────────────
printf '\n]\n' >> "${CREDS_TMP}"
jq --arg svc "gitea" --arg url "${GITEA_URL}" \
  '{"service":$svc,"baseurl":$url,"users":.}' "${CREDS_TMP}" > "${CREDS_FILE}"
chmod 600 "${CREDS_FILE}"
rm -f "${CREDS_TMP}"

touch "${PROVISION_STAMP}"
echo "[provision-users] Done. Credentials written to ${CREDS_FILE}."
