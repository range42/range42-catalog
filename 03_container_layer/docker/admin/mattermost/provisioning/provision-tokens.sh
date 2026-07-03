#!/usr/bin/env bash
#
# ISSUE 143
#
# provision-tokens.sh — generates a Mattermost personal access token for
# every user listed in mm-credentials.json and writes username:token lines
# to /tokens/tokens.txt.
#
# Requires provision-users.sh to have completed successfully first.
#
set -euo pipefail

TOKENS_DIR="/tokens"
CREDS_FILE="${TOKENS_DIR}/mm-credentials.json"
TOKENS_FILE="${TOKENS_DIR}/tokens.txt"

MM_URL="$(jq -r '.baseurl' "${CREDS_FILE}")"
MM_ADMIN_USER="$(jq -r '.users[] | select(.role=="admin") | .username' "${CREDS_FILE}")"
MM_ADMIN_PASS="$(jq -r '.users[] | select(.role=="admin") | .password' "${CREDS_FILE}")"

# Login as admin (needed to generate tokens for other users)
echo "[provision-tokens] Logging in as admin ..."
auth_resp=$(curl -sf -D - -X POST "${MM_URL}/api/v4/users/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "${MM_ADMIN_USER}" --arg p "${MM_ADMIN_PASS}" \
    '{"login_id":$u,"password":$p}')")
ADMIN_TOKEN=$(printf '%s' "${auth_resp}" | grep -i '^Token:' | awk '{print $2}' | tr -d '\r')

if [ -z "${ADMIN_TOKEN}" ]; then
  echo "[fatal] Could not obtain admin token. Aborting."
  exit 1
fi

echo "[provision-tokens] Generating personal access tokens ..."
: > "${TOKENS_FILE}"

while IFS= read -r entry; do
  username="$(printf '%s' "${entry}" | jq -r '.username')"

  uid=$(curl -sf "${MM_URL}/api/v4/users/username/${username}" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" | jq -r '.id // empty')

  if [ -z "${uid}" ]; then
    printf '%s:ERROR_user_not_found\n' "${username}" >> "${TOKENS_FILE}"
    echo "[warn] User not found: ${username}"
    continue
  fi

  token_resp=$(curl -sf -X POST "${MM_URL}/api/v4/users/${uid}/tokens" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"description":"API access token"}')
  token_val=$(printf '%s' "${token_resp}" | jq -r '.token // empty')

  if [ -n "${token_val}" ]; then
    printf '%s:%s\n' "${username}" "${token_val}" >> "${TOKENS_FILE}"
    echo "[provision-tokens]   + token for ${username}"
  else
    printf '%s:ERROR\n' "${username}" >> "${TOKENS_FILE}"
    echo "[warn] Could not create token for ${username}"
  fi
done < <(jq -c '.users[]' "${CREDS_FILE}")

chmod 600 "${TOKENS_FILE}"
echo "[provision-tokens] Done. Tokens written to ${TOKENS_FILE}."
