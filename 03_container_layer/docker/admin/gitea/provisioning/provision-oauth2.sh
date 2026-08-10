#!/usr/bin/env bash
#
# ISSUE 171
#
# provision-oauth2.sh — register an OAuth2 application in Gitea so a consumer
# service (Mattermost, Rocket.Chat, Nextcloud, …) can delegate auth here.
#
# This script is NOT called automatically by provision.sh at stack startup —
# redirect URIs are only known once consumer services are up. Call it from the
# scenario playbook (or manually) after all stacks are running.
#
# Usage (via docker compose):
#   docker compose run --rm \
#     --entrypoint /provisioning/provision-oauth2.sh \
#     -e GITEA_OAUTH2_SERVICE_NAME=mattermost \
#     -e GITEA_OAUTH2_REDIRECT_URI=https://mattermost.lab/oauth/gitea/complete \
#     provisioner
#
# Or with positional args:
#   docker compose run --rm \
#     --entrypoint /provisioning/provision-oauth2.sh \
#     provisioner mattermost https://mattermost.lab/oauth/gitea/complete
#
# On success, appends to /tokens/gitea-credentials.json under .oauth2_apps[].
# Idempotent: skips creation if the app name already exists in the JSON.
#
set -euo pipefail

GITEA_URL="${GITEA_URL:-http://gitea:3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-Admin1234!}"
TOKENS_DIR="/tokens"
CREDS_FILE="${TOKENS_DIR}/gitea-credentials.json"

# positional args override env vars
SERVICE_NAME="${1:-${GITEA_OAUTH2_SERVICE_NAME:-}}"
REDIRECT_URI="${2:-${GITEA_OAUTH2_REDIRECT_URI:-}}"

if [ -z "${SERVICE_NAME}" ] || [ -z "${REDIRECT_URI}" ]; then
  echo "[error] Usage: provision-oauth2.sh <service_name> <redirect_uri>"
  echo "        or set GITEA_OAUTH2_SERVICE_NAME and GITEA_OAUTH2_REDIRECT_URI env vars"
  exit 1
fi

# ── 1. Wait for Gitea ─────────────────────────────────────────────────────────
echo "[provision-oauth2] Waiting for Gitea at ${GITEA_URL} ..."
attempts=0
until curl -sfk "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 30 ]; then
    echo "[fatal] Gitea did not respond after 90 s. Aborting."
    exit 1
  fi
  sleep 3
done

# ── 2. Idempotency: check credentials JSON first ──────────────────────────────
if [ -f "${CREDS_FILE}" ]; then
  existing=$(jq -r --arg name "${SERVICE_NAME}" \
    '.oauth2_apps // [] | map(select(.service == $name)) | first | .client_id // empty' \
    "${CREDS_FILE}")
  if [ -n "${existing}" ]; then
    echo "[provision-oauth2] App '${SERVICE_NAME}' already registered (client_id: ${existing}). Skipping."
    exit 0
  fi
fi

# ── 3. Register the OAuth2 application ───────────────────────────────────────
echo "[provision-oauth2] Registering OAuth2 app for '${SERVICE_NAME}' ..."
resp=$(curl -sk -X POST "${GITEA_URL}/api/v1/user/applications/oauth2" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
    --arg name "${SERVICE_NAME}" \
    --arg uri  "${REDIRECT_URI}" \
    '{"name":$name,"redirect_uris":[$uri],"confidential_client":true}')")

client_id=$(printf '%s' "${resp}" | jq -r '.client_id // empty')
client_secret=$(printf '%s' "${resp}" | jq -r '.client_secret // empty')

if [ -z "${client_id}" ] || [ -z "${client_secret}" ]; then
  echo "[error] Failed to register OAuth2 app for '${SERVICE_NAME}':"
  printf '%s\n' "${resp}" | jq '.' 2>/dev/null || printf '%s\n' "${resp}"
  exit 1
fi

# ── 4. Append to credentials JSON ────────────────────────────────────────────
if [ -f "${CREDS_FILE}" ]; then
  jq --arg svc "${SERVICE_NAME}" \
     --arg cid "${client_id}" \
     --arg cs  "${client_secret}" \
     --arg ru  "${REDIRECT_URI}" \
     '.oauth2_apps = ((.oauth2_apps // []) + [{"service":$svc,"client_id":$cid,"client_secret":$cs,"redirect_uri":$ru}])' \
     "${CREDS_FILE}" > "${CREDS_FILE}.tmp" && mv "${CREDS_FILE}.tmp" "${CREDS_FILE}"
  chmod 600 "${CREDS_FILE}"
fi

echo "[provision-oauth2] Done."
echo "  service      : ${SERVICE_NAME}"
echo "  client_id    : ${client_id}"
echo "  client_secret: ${client_secret}"
echo "  redirect_uri : ${REDIRECT_URI}"
echo ""
echo "Gitea OAuth2 endpoints:"
echo "  authorize : ${GITEA_URL}/login/oauth/authorize"
echo "  token     : ${GITEA_URL}/login/oauth/access_token"
echo "  userinfo  : ${GITEA_URL}/login/oauth/userinfo"
echo "  discovery : ${GITEA_URL}/.well-known/openid-configuration"
