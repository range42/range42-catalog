#!/usr/bin/env sh
#
# ISSUE 142
#
# Bootstrap script for the Gitea Docker registry provisioner sidecar.
# Runs once after Gitea is healthy; guarded by a stamp file for idempotency.
#
# User/SSH-key declarations come from USERS_FILE (default: /provisioning/users.yml).
# Admin users are created via the gitea CLI (direct DB access via app.ini).
# SSH keys are injected via the Gitea REST API.
# Personal access tokens are generated for each user and written to /tokens/tokens.txt.
#
set -eu

GITEA_URL="${GITEA_URL:-http://gitea:3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-Admin1234!}"
USERS_FILE="${USERS_FILE:-/provisioning/users.yml}"
GITEA_CONFIG="/data/gitea/conf/app.ini"
PROVISION_STAMP="/data/gitea/.provisioned"
GITEA_WEBHOOK_URL="${GITEA_WEBHOOK_URL:-}"
GITEA_WEBHOOK_CHANNEL="${GITEA_WEBHOOK_CHANNEL:-#general}"
GITEA_PKG_KEEP_COUNT="${GITEA_PKG_KEEP_COUNT:-10}"
GITEA_PKG_REMOVE_DAYS="${GITEA_PKG_REMOVE_DAYS:-30}"

# ── 1. Wait for Gitea HTTP (max 180 s) ─────────────────────────────────────
echo "[init] Waiting for Gitea at ${GITEA_URL} ..."
attempts=0
until curl -sfk "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; do
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
      *) echo "[error] Failed to create ${username}: ${cli_out}"; exit 1 ;;
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
      *) echo "[error] Failed to create ${username}: ${cli_out}"; exit 1 ;;
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
      curl -sfk -X POST "${GITEA_URL}/api/v1/admin/users/${uname}/keys" \
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

# ── 6. Org namespaces (issue #172: per-team + pre-warmed admin image set) ────
echo "[init] Creating org namespaces ..."
org_count=$(yq e '.orgs | length' "${USERS_FILE}" 2>/dev/null || echo 0)
i=0
while [ "${i}" -lt "${org_count}" ]; do
  org_name=$(yq e ".orgs[${i}].name" "${USERS_FILE}")
  org_desc=$(yq e ".orgs[${i}].description // \"\"" "${USERS_FILE}")
  if curl -sfk "${GITEA_URL}/api/v1/orgs/${org_name}" \
       -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" >/dev/null 2>&1; then
    echo "[warn] org ${org_name} already exists — skipping"
  else
    echo "[init]   + org: ${org_name}"
    payload=$(jq -n --arg n "${org_name}" --arg d "${org_desc}" \
      '{"username":$n,"description":$d,"visibility":"public"}')
    curl -sfk -X POST "${GITEA_URL}/api/v1/orgs" \
      -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      -H "Content-Type: application/json" \
      -d "${payload}" >/dev/null \
      || { echo "[error] Failed to create org ${org_name}"; exit 1; }
  fi
  i=$((i + 1))
done

# ── 7. Registry tokens (issue #172: push vs pull auth scheme) ────────────────
# admins → read:package + write:package (operator push credential)
# users  → read:package only (lab VM pull credential), unless the entry sets
#          registry_role: push.
create_tokens() {
  local section="${1}" default_role="${2}"
  local count j uname role scopes token_resp token_val payload

  count=$(yq e ".${section} | length" "${USERS_FILE}")
  j=0
  while [ "${j}" -lt "${count}" ]; do
    uname=$(yq e ".${section}[${j}].username" "${USERS_FILE}")
    role=$(yq e ".${section}[${j}].registry_role // \"${default_role}\"" "${USERS_FILE}")
    if [ "${role}" = "push" ]; then
      scopes='["read:package","write:package"]'
    else
      scopes='["read:package"]'
    fi
    echo "[init]   + registry token for ${uname} (${role})"
    payload=$(jq -n --arg n "registry-token" --argjson s "${scopes}" \
      '{"name":$n,"scopes":$s}')
    token_resp=$(curl -sfk -X POST "${GITEA_URL}/api/v1/users/${uname}/tokens" \
      -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      -H "Content-Type: application/json" \
      -d "${payload}" || echo '{}')
    token_val=$(echo "${token_resp}" | jq -r '.sha1 // "ERROR"')
    echo "[token] ${uname}: ${token_val}"
    echo "${uname}:${token_val}:$(echo "${scopes}" | jq -r 'join(",")')" >> /tokens/tokens.txt
    j=$((j + 1))
  done
}

mkdir -p /tokens
echo "# Generated by gitea-registry provisioner" > /tokens/tokens.txt
echo "# Format: username:token:scopes" >> /tokens/tokens.txt
echo "# docker login usage: docker login DOMAIN:PORT -u USERNAME -p TOKEN" >> /tokens/tokens.txt
echo "[init] Generating registry tokens ..."
create_tokens admins push
create_tokens users pull
echo "[init] Tokens written to /tokens/tokens.txt"

# ── 8. Per-image retention rules (issue #172: keep last N, delete older) ────
# Gitea 1.27 exposes package cleanup rules only through the web UI (no REST
# API endpoint — verified against swagger.v1.json), so this drives the HTML
# form with a session cookie + CSRF token. One container-type rule per owner:
# the admin user plus every org from users.yml.
_JAR=$(mktemp)
web_login() {
  local csrf
  curl -sfk -c "${_JAR}" "${GITEA_URL}/user/login" -o /dev/null
  csrf=$(awk '$6 == "_csrf" {print $7}' "${_JAR}" | tail -1)
  curl -sfk -b "${_JAR}" -c "${_JAR}" -o /dev/null -X POST "${GITEA_URL}/user/login" \
    --data-urlencode "_csrf=${csrf}" \
    --data-urlencode "user_name=${GITEA_ADMIN_USER}" \
    --data-urlencode "password=${GITEA_ADMIN_PASS}"
}

add_cleanup_rule() {
  local form_path="${1}" owner="${2}" csrf http_code
  # Refresh CSRF from the form page (token rotates per session state).
  curl -sk -b "${_JAR}" -c "${_JAR}" "${GITEA_URL}${form_path}" -o /dev/null
  csrf=$(awk '$6 == "_csrf" {print $7}' "${_JAR}" | tail -1)
  http_code=$(curl -sk -b "${_JAR}" -c "${_JAR}" -o /dev/null -w '%{http_code}' \
    -X POST "${GITEA_URL}${form_path}" \
    --data-urlencode "_csrf=${csrf}" \
    --data-urlencode "id=0" \
    --data-urlencode "enabled=on" \
    --data-urlencode "type=container" \
    --data-urlencode "keep_count=${GITEA_PKG_KEEP_COUNT}" \
    --data-urlencode "keep_pattern=" \
    --data-urlencode "remove_days=${GITEA_PKG_REMOVE_DAYS}" \
    --data-urlencode "remove_pattern=" \
    --data-urlencode "match_full_name=" \
    --data-urlencode "action=save")
  if [ "${http_code}" = "303" ] || [ "${http_code}" = "302" ]; then
    echo "[init]   + cleanup rule (container, keep ${GITEA_PKG_KEEP_COUNT}, purge >${GITEA_PKG_REMOVE_DAYS}d) for ${owner}"
  else
    echo "[warn] cleanup rule for ${owner} returned HTTP ${http_code} — configure manually in the UI"
  fi
}

echo "[init] Configuring package cleanup rules ..."
web_login
add_cleanup_rule "/user/settings/packages/rules/add" "${GITEA_ADMIN_USER}"
i=0
while [ "${i}" -lt "${org_count}" ]; do
  org_name=$(yq e ".orgs[${i}].name" "${USERS_FILE}")
  add_cleanup_rule "/org/${org_name}/settings/packages/rules/add" "${org_name}"
  i=$((i + 1))
done
rm -f "${_JAR}"

# ── 9. Webhook on package push (issue #172) ──────────────────────────────────
# System-wide hook (fires for all owners) in Slack format — Rocket.Chat's
# incoming webhook accepts Gitea Slack payloads when the integration has
# overrideDestinationChannelEnabled: true. Left empty at first boot in the
# admin_services_lab flow (Rocket.Chat comes up later); stage_02 wires it via
# the same /admin/hooks API afterwards.
if [ -n "${GITEA_WEBHOOK_URL}" ]; then
  existing_hook=$(curl -sfk "${GITEA_URL}/api/v1/admin/hooks" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" 2>/dev/null \
    | jq -r --arg u "${GITEA_WEBHOOK_URL}" '.[] | select(.config.url == $u) | .id' | head -1) || true
  if [ -n "${existing_hook}" ]; then
    echo "[init] Package webhook already registered (hook id ${existing_hook}) — skipping."
  else
    echo "[init] Registering package push webhook -> ${GITEA_WEBHOOK_URL}"
    # is_system_webhook selects a SYSTEM hook (fires on package events);
    # without it /admin/hooks creates a repo-template "default" hook instead.
    payload=$(jq -n --arg u "${GITEA_WEBHOOK_URL}" --arg ch "${GITEA_WEBHOOK_CHANNEL}" \
      '{"type":"slack","active":true,"events":["package"],
        "config":{"url":$u,"content_type":"json","channel":$ch,"is_system_webhook":"true"}}')
    curl -sfk -X POST "${GITEA_URL}/api/v1/admin/hooks" \
      -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      -H "Content-Type: application/json" \
      -d "${payload}" >/dev/null \
      || echo "[warn] Failed to register package webhook — register manually or via stage_02"
  fi
else
  echo "[init] GITEA_WEBHOOK_URL empty — skipping package webhook."
fi

# ── 10. Export TLS certificate so clients can trust it for docker login ──────
if [ -f "/certs/server.crt" ]; then
  cp /certs/server.crt /tokens/registry-cert.pem
  echo "[init] TLS certificate copied to /tokens/registry-cert.pem"
fi

# ── 11. Mark as provisioned ──────────────────────────────────────────────────
touch "${PROVISION_STAMP}"
echo "[init] Provisioning complete."
