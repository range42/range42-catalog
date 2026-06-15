#!/usr/bin/env bash
# ISSUE 142 — creates admin (CLI), instructors, leads, team users (REST API)
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
CREDS_FILE="${TOKENS_DIR}/gitea-registry-credentials.json"
PROVISION_STAMP="${TOKENS_DIR}/.provisioned"

gen_password() {
  printf 'R42!%s' "$(openssl rand -base64 16 | tr -d '/+=')" | head -c 20
}

# ── Wait for Gitea HTTP (max 180 s) ─────────────────────────────────────────
echo "[provision-users] Waiting for Gitea at ${GITEA_URL} ..."
attempts=0
until curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Gitea did not become healthy after 180 s."
    exit 1
  fi
  sleep 3
done
echo "[provision-users] Gitea is up."

# ── Idempotency guard ────────────────────────────────────────────────────────
if [ -f "${PROVISION_STAMP}" ]; then
  echo "[provision-users] Already provisioned (stamp at ${PROVISION_STAMP}). Exiting."
  exit 0
fi

mkdir -p "${TOKENS_DIR}"
chmod 700 "${TOKENS_DIR}"

# ── MISP accumulator setup ───────────────────────────────────────────────────
CREDS_TMP="$(mktemp)"
printf '[\n' > "${CREDS_TMP}"
_CRED_FIRST=true

append_cred() {
  local username="${1}" password="${2}" role="${3}"
  if [ "${_CRED_FIRST}" = "true" ]; then
    _CRED_FIRST=false
  else
    printf ',\n' >> "${CREDS_TMP}"
  fi
  jq -n --arg u "${username}" --arg p "${password}" --arg r "${role}" \
    '{"username":$u,"password":$p,"role":$r}' >> "${CREDS_TMP}"
}

# ── Admin user (Gitea CLI — direct DB) ──────────────────────────────────────
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
    *) echo "[error] Failed to create admin: ${cli_out}"; exit 1 ;;
  esac
}
append_cred "${GITEA_ADMIN_USER}" "${GITEA_ADMIN_PASS}" "admin"

# ── Helper: create user via REST API ────────────────────────────────────────
create_user() {
  local username="${1}" password="${2}" email="${3}"
  local payload
  payload=$(jq -n \
    --arg u "${username}" \
    --arg p "${password}" \
    --arg e "${email}" \
    '{"email":$e,"login_name":$u,"must_change_password":false,"password":$p,"send_notify":false,"source_id":0,"username":$u}')
  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${GITEA_URL}/api/v1/admin/users" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d "${payload}" 2>/dev/null) || true
  case "${http_code}" in
    201) echo "[provision-users]   + ${username}" ;;
    422) echo "[warn] ${username} already exists — skipping" ;;
    *)   echo "[error] Unexpected HTTP ${http_code} creating ${username}"; exit 1 ;;
  esac
}

# ── Instructors ──────────────────────────────────────────────────────────────
i=1
while [ "${i}" -le "${GITEA_INSTRUCTOR_COUNT}" ]; do
  uname="$(printf 'instructor-%02d' "${i}")"
  pass="$(gen_password)"
  email="${uname}@${GITEA_USER_DOMAIN}"
  create_user "${uname}" "${pass}" "${email}"
  append_cred "${uname}" "${pass}" "instructor"
  i=$((i + 1))
done

# ── Teams: lead + users ──────────────────────────────────────────────────────
IFS=',' read -ra TEAM_LIST <<< "${GITEA_TEAMS}"
for team in "${TEAM_LIST[@]}"; do
  # Team lead
  lead="${team}-lead"
  lead_pass="$(gen_password)"
  lead_email="${lead}@${GITEA_USER_DOMAIN}"
  create_user "${lead}" "${lead_pass}" "${lead_email}"
  append_cred "${lead}" "${lead_pass}" "lead"

  # Team members
  j=1
  while [ "${j}" -le "${GITEA_USERS_PER_TEAM}" ]; do
    uname="$(printf '%s-user-%02d' "${team}" "${j}")"
    pass="$(gen_password)"
    email="${uname}@${GITEA_USER_DOMAIN}"
    create_user "${uname}" "${pass}" "${email}"
    append_cred "${uname}" "${pass}" "user"
    j=$((j + 1))
  done
done

# ── Finalise credentials JSON ────────────────────────────────────────────────
printf '\n]\n' >> "${CREDS_TMP}"
jq --arg svc "gitea-registry" --arg url "${GITEA_URL}" \
  '{"service":$svc,"baseurl":$url,"users":.}' "${CREDS_TMP}" > "${CREDS_FILE}"
rm -f "${CREDS_TMP}"
chmod 600 "${CREDS_FILE}"

touch "${PROVISION_STAMP}"
echo "[provision-users] Done. Credentials → ${CREDS_FILE}"
