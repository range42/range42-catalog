#!/usr/bin/env bash
#
# ISSUE 141
#
# provision-tokens.sh — generates a Gitea API token for every user listed
# in gitea-credentials.json and writes username:token lines to tokens.txt.
#
# Each user authenticates with their own credentials to create their token
# via POST /api/v1/users/{username}/tokens. The response field is .sha1.
#
# Requires provision-users.sh to have completed successfully first.
#
set -euo pipefail

TOKENS_DIR="/tokens"
CREDS_FILE="${TOKENS_DIR}/gitea-credentials.json"
TOKENS_FILE="${TOKENS_DIR}/tokens.txt"

GITEA_URL="$(jq -r '.baseurl' "${CREDS_FILE}")"

echo "[provision-tokens] Generating Gitea API tokens ..."
: > "${TOKENS_FILE}"

while IFS= read -r entry; do
  username="$(printf '%s' "${entry}" | jq -r '.username')"
  password="$(printf '%s' "${entry}" | jq -r '.password')"

  token_resp=$(curl -sk --max-time 30 -X POST "${GITEA_URL}/api/v1/users/${username}/tokens" \
    -u "${username}:${password}" \
    -H "Content-Type: application/json" \
    -d '{"name":"API access token"}') || true
  token_val=$(printf '%s' "${token_resp}" | jq -r '.sha1 // empty')

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
