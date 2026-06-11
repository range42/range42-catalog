#!/usr/bin/env sh
#
# ISSUE 141
#
# Bootstrap script for the Gitea provisioner sidecar.
# Runs once after Gitea is healthy; guarded by a stamp file for idempotency.
#
# User/SSH-key declarations come from USERS_FILE (default: /provisioning/users.yml).
# Admin users are created via the gitea CLI (direct DB access via app.ini).
# SSH keys are injected via the Gitea REST API.
#
set -eu

GITEA_URL="${GITEA_URL:-http://gitea:3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-Admin1234!}"
USERS_FILE="${USERS_FILE:-/provisioning/users.yml}"
GITEA_CONFIG="/data/gitea/conf/app.ini"
PROVISION_STAMP="/data/gitea/.provisioned"

# ── 1. Wait for Gitea HTTP (max 180 s) ─────────────────────────────────────
echo "[init] Waiting for Gitea at ${GITEA_URL} ..."
attempts=0
until curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Gitea did not become healthy after 180 s. Aborting."
    exit 1
  fi
  sleep 3
done
echo "[init] Gitea is up."

# ── 2. Idempotency guard ────────────────────────────────────────────────────
if [ -f "${PROVISION_STAMP}" ]; then
  echo "[init] Already provisioned (stamp found at ${PROVISION_STAMP}). Exiting."
  exit 0
fi

# ── 3. Admin users (gitea CLI — direct DB, no HTTP auth needed) ─────────────
admin_count=$(yq e '.admins | length' "${USERS_FILE}")
echo "[init] Creating ${admin_count} admin user(s) ..."

i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username" "${USERS_FILE}")
  email=$(yq e ".admins[${i}].email"    "${USERS_FILE}")
  password=$(yq e ".admins[${i}].password" "${USERS_FILE}")

  echo "[init]   + admin: ${username}"
  cli_out=$(gitea admin user create \
    --config "${GITEA_CONFIG}" \
    --admin \
    --username "${username}" \
    --password "${password}" \
    --email    "${email}" \
    --must-change-password=false 2>&1) || {
    case "${cli_out}" in
      *"user already exists"*|*"name already exists"*)
        echo "[warn] ${username} already exists — skipping" ;;
      *)
        echo "[error] Failed to create ${username}: ${cli_out}"; exit 1 ;;
    esac
  }

  i=$((i + 1))
done

# ── 4. Regular users (gitea CLI) ────────────────────────────────────────────
user_count=$(yq e '.users | length' "${USERS_FILE}")
echo "[init] Creating ${user_count} regular user(s) ..."

i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username" "${USERS_FILE}")
  email=$(yq e ".users[${i}].email"    "${USERS_FILE}")
  password=$(yq e ".users[${i}].password" "${USERS_FILE}")

  echo "[init]   + user: ${username}"
  cli_out=$(gitea admin user create \
    --config "${GITEA_CONFIG}" \
    --username "${username}" \
    --password "${password}" \
    --email    "${email}" \
    --must-change-password=false 2>&1) || {
    case "${cli_out}" in
      *"user already exists"*|*"name already exists"*)
        echo "[warn] ${username} already exists — skipping" ;;
      *)
        echo "[error] Failed to create ${username}: ${cli_out}"; exit 1 ;;
    esac
  }

  i=$((i + 1))
done

# ── 5. SSH keys (REST API — first admin in users.yml acts as auth) ──────────
inject_keys() {
  local section="${1}"
  local count j k uname key_count key

  count=$(yq e ".${section} | length" "${USERS_FILE}")
  j=0
  while [ "${j}" -lt "${count}" ]; do
    uname=$(yq e ".${section}[${j}].username" "${USERS_FILE}")
    key_count=$(yq e ".${section}[${j}].ssh_keys | length" "${USERS_FILE}")

    k=0
    while [ "${k}" -lt "${key_count}" ]; do
      key=$(yq e ".${section}[${j}].ssh_keys[${k}]" "${USERS_FILE}")
      echo "[init]   + SSH key ${k} -> ${uname}"
      # Use jq to build the JSON payload to avoid injection via crafted key strings.
      payload=$(jq -n --arg k "${key}" --arg t "${uname}-key-${k}" \
        '{"key":$k,"read_only":false,"title":$t}')
      curl -sf -X POST "${GITEA_URL}/api/v1/admin/users/${uname}/keys" \
        -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        >/dev/null \
        || echo "[warn] SSH key ${k} for ${uname} may already exist — skipping"
      k=$((k + 1))
    done

    j=$((j + 1))
  done
}

echo "[init] Injecting SSH keys ..."
inject_keys admins
inject_keys users

# ── 6. Mark as provisioned ──────────────────────────────────────────────────
touch "${PROVISION_STAMP}"
echo "[init] Provisioning complete."
