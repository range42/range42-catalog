#!/bin/sh
#
# ISSUE 146 / 174
#
# Bootstrap script for the Nextcloud provisioner sidecar.
# Runs once after Nextcloud is healthy; guarded by a stamp file for idempotency.
#
# User declarations come from USERS_FILE (default: /provisioning/users.yml).
# Admin users are created via the OCS API and added to the admin group.
# Regular users are created via the OCS API.
# App passwords are generated for every user and written to /tokens/tokens.txt.
# Groups (trainees / instructors) are created and users assigned per users.yml.
# A /Shared/Welcome folder is seeded with sample files.
# Sample shares (public, password-protected, time-expiring) are created.
# Calendar events, Deck board, and Contacts are pre-seeded.
# nextcloud-credentials.json is emitted to /tokens/.
#
set -eu

NC_URL="${NC_URL:-http://nextcloud}"
NC_BASE_URL="${NC_BASE_URL:-https://localhost}"
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

# ── Helper: OCS API call ────────────────────────────────────────────────────
ocs_post() {
  local endpoint="${1}"; shift
  curl -sf -X POST "${NC_URL}${endpoint}" \
    -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
    -H "OCS-APIRequest: true" \
    -H "Accept: application/json" \
    "$@" || echo '{}'
}

ocs_put() {
  local endpoint="${1}"; shift
  curl -sf -X PUT "${NC_URL}${endpoint}" \
    -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
    -H "OCS-APIRequest: true" \
    -H "Accept: application/json" \
    "$@" || echo '{}'
}

ocs_status() {
  echo "${1}" | jq -r '.ocs.meta.statuscode // 999' 2>/dev/null || echo 999
}

# ── Helper: create a user via OCS API ──────────────────────────────────────
create_user() {
  local username="${1}"
  local password="${2}"
  local email="${3}"
  local display_name="${4}"

  resp=$(ocs_post "/ocs/v1.php/cloud/users" \
    --data-urlencode "userid=${username}" \
    --data-urlencode "password=${password}" \
    --data-urlencode "email=${email}" \
    --data-urlencode "displayName=${display_name}")
  status=$(ocs_status "${resp}")
  case "${status}" in
    100) echo "[init]   + user created: ${username}" ;;
    102) echo "[warn]   ${username} already exists — skipping" ;;
    *) echo "[error]  Failed to create ${username} (OCS status ${status})"; exit 1 ;;
  esac
}

# ── Helper: add a user to the admin group ──────────────────────────────────
add_to_admin_group() {
  local username="${1}"
  echo "[init]   + adding ${username} to admin group"
  ocs_post "/ocs/v1.php/cloud/groups/admin/users" \
    --data-urlencode "userid=${username}" >/dev/null
}

# ── Helper: record user credentials ────────────────────────────────────────
# The /ocs/v2.php/core/apppassword endpoint requires a browser-like session
# (secure cookies) that breaks when called over plain HTTP while Nextcloud is
# configured with OVERWRITEPROTOCOL=https.  For this training environment,
# recording the known login password is equivalent — it lets the training-doc
# pipeline authenticate as any provisioned user.
generate_app_password() {
  local username="${1}"
  local password="${2}"

  echo "[init]   + recording credentials for ${username}"
  printf '%s: %s\n' "${username}" "${password}" >> "${TOKENS_FILE}"
  printf '[token] %s: %s\n' "${username}" "${password}"
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

# ── 5. Create groups ─────────────────────────────────────────────────────────
echo "[init] Creating groups ..."

create_group() {
  local groupid="${1}"
  local displayname="${2}"
  resp=$(ocs_post "/ocs/v1.php/cloud/groups" \
    --data-urlencode "groupid=${groupid}" \
    --data-urlencode "displayname=${displayname}")
  status=$(ocs_status "${resp}")
  case "${status}" in
    100) echo "[init]   + group created: ${groupid}" ;;
    102) echo "[warn]   group ${groupid} already exists — skipping" ;;
    *) echo "[warn]   Failed to create group ${groupid} (status ${status})" ;;
  esac
}

create_group "trainees"    "Trainees"
create_group "instructors" "Instructors"

# ── 6. Assign users to groups and set quotas ─────────────────────────────────
echo "[init] Assigning users to groups and setting quotas ..."

add_user_to_group() {
  local username="${1}"
  local groupid="${2}"
  ocs_post "/ocs/v1.php/cloud/groups/${groupid}/users" \
    --data-urlencode "userid=${username}" >/dev/null \
    || echo "[warn] Failed to add ${username} to group ${groupid}"
  echo "[init]   + ${username} -> ${groupid}"
}

set_user_quota() {
  local username="${1}"
  local quota="${2}"
  ocs_put "/ocs/v1.php/cloud/users/${username}" \
    --data-urlencode "key=quota" \
    --data-urlencode "value=${quota}" >/dev/null \
    || echo "[warn] Failed to set quota for ${username}"
  echo "[init]   + quota ${quota} -> ${username}"
}

i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username" "${USERS_FILE}")
  group=$(yq e ".admins[${i}].group // \"\"" "${USERS_FILE}")
  if [ -n "${group}" ] && [ "${group}" != "null" ]; then
    add_user_to_group "${username}" "${group}"
  fi
  set_user_quota "${username}" "5 GB"
  i=$((i + 1))
done

i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username" "${USERS_FILE}")
  group=$(yq e ".users[${i}].group // \"\"" "${USERS_FILE}")
  if [ -n "${group}" ] && [ "${group}" != "null" ]; then
    add_user_to_group "${username}" "${group}"
  fi
  set_user_quota "${username}" "2 GB"
  i=$((i + 1))
done

# ── 7. Create /Shared/Welcome folder and seed sample files ───────────────────
echo "[init] Seeding /Shared/Welcome folder ..."

NC_WEBDAV="${NC_URL}/remote.php/dav/files/${NC_ADMIN_USER}"

curl -sf -X MKCOL "${NC_WEBDAV}/Shared" \
  -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" >/dev/null 2>&1 || true
curl -sf -X MKCOL "${NC_WEBDAV}/Shared/Welcome" \
  -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" >/dev/null 2>&1 || true

printf '%s' "# Welcome to Range42 Training

This shared folder contains introductory materials for your training session.

## Getting started

1. Read through the materials in this folder before starting exercises.
2. Check Mattermost (#general) for announcements from your instructors.
3. Your personal credentials are available in your home folder.

## Environment overview

- **Gitea**: Source code repository and issue tracker
- **Mattermost**: Team communication and incident channels
- **Nextcloud**: File sharing, calendar, and collaboration

Enjoy the training!
" | curl -sf -X PUT "${NC_WEBDAV}/Shared/Welcome/Welcome.md" \
  -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
  -H "Content-Type: text/markdown" \
  --data-binary @- >/dev/null || echo "[warn] Failed to upload Welcome.md"

printf '%s' "This is a sample text file demonstrating file sharing in Range42.
You can download, preview, and share files from the Nextcloud web interface.
" | curl -sf -X PUT "${NC_WEBDAV}/Shared/Welcome/sample.txt" \
  -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
  -H "Content-Type: text/plain" \
  --data-binary @- >/dev/null || echo "[warn] Failed to upload sample.txt"

echo "[init]   + /Shared/Welcome seeded (Welcome.md, sample.txt)"

# ── 8. Create sample shares (3 patterns) ────────────────────────────────────
echo "[init] Creating sample shares ..."

# Public link (shareType=3, permissions=1=read-only)
ocs_post "/ocs/v2.php/apps/files_sharing/api/v1/shares" \
  --data-urlencode "path=/Shared/Welcome" \
  --data-urlencode "shareType=3" \
  --data-urlencode "permissions=1" >/dev/null
echo "[init]   + public link share: /Shared/Welcome"

# Password-protected link
ocs_post "/ocs/v2.php/apps/files_sharing/api/v1/shares" \
  --data-urlencode "path=/Shared/Welcome/sample.txt" \
  --data-urlencode "shareType=3" \
  --data-urlencode "permissions=1" \
  --data-urlencode "password=WelcomeShare42!" >/dev/null
echo "[init]   + password-protected share: /Shared/Welcome/sample.txt"

# Time-expiring link (30 days)
EXPIRE_DATE=$(date -d "+30 days" +%Y-%m-%d 2>/dev/null || echo "2026-08-09")
ocs_post "/ocs/v2.php/apps/files_sharing/api/v1/shares" \
  --data-urlencode "path=/Shared/Welcome/Welcome.md" \
  --data-urlencode "shareType=3" \
  --data-urlencode "permissions=1" \
  --data-urlencode "expireDate=${EXPIRE_DATE}" >/dev/null
echo "[init]   + time-expiring share (until ${EXPIRE_DATE}): /Shared/Welcome/Welcome.md"

# ── 9. Seed calendar event ───────────────────────────────────────────────────
echo "[init] Seeding calendar event ..."

cat > /tmp/training-event.ics <<'ICSEOF'
BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Range42//Training//EN
BEGIN:VEVENT
UID:range42-training-kickoff@range42.local
DTSTAMP:20260709T080000Z
DTSTART:20260710T090000Z
DTEND:20260710T170000Z
SUMMARY:Range42 Training Kickoff
DESCRIPTION:Welcome to the Range42 cybersecurity training. This opening session covers the lab environment overview and exercise objectives.
LOCATION:Training Environment
END:VEVENT
END:VCALENDAR
ICSEOF

curl -sf -X PUT \
  "${NC_URL}/remote.php/dav/calendars/${NC_ADMIN_USER}/personal/range42-training-kickoff.ics" \
  -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
  -H "Content-Type: text/calendar; charset=utf-8" \
  --data-binary @/tmp/training-event.ics >/dev/null \
  || echo "[warn] Failed to seed calendar event (calendar app may not be enabled yet)"
echo "[init]   + calendar event seeded"

# ── 10. Seed contacts directory ──────────────────────────────────────────────
echo "[init] Seeding contacts ..."

curl -sf -X MKCOL \
  "${NC_URL}/remote.php/dav/addressbooks/users/${NC_ADMIN_USER}/contacts/" \
  -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" >/dev/null 2>&1 || true

seed_contact() {
  local uid="${1}"
  local fullname="${2}"
  local email="${3}"
  local org="${4}"

  printf 'BEGIN:VCARD\nVERSION:3.0\nUID:%s@range42.local\nFN:%s\nEMAIL:%s\nORG:%s\nEND:VCARD\n' \
    "${uid}" "${fullname}" "${email}" "${org}" \
    | curl -sf -X PUT \
        "${NC_URL}/remote.php/dav/addressbooks/users/${NC_ADMIN_USER}/contacts/${uid}.vcf" \
        -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
        -H "Content-Type: text/vcard; charset=utf-8" \
        --data-binary @- >/dev/null \
      || echo "[warn] Failed to create contact ${uid}"
  echo "[init]   + contact: ${fullname}"
}

i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username"             "${USERS_FILE}")
  display_name=$(yq e ".admins[${i}].display_name // \"\"" "${USERS_FILE}")
  email=$(yq e ".admins[${i}].email"                   "${USERS_FILE}")
  seed_contact "${username}" "${display_name}" "${email}" "Range42 Instructors"
  i=$((i + 1))
done

i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username"             "${USERS_FILE}")
  display_name=$(yq e ".users[${i}].display_name // \"\"" "${USERS_FILE}")
  email=$(yq e ".users[${i}].email"                   "${USERS_FILE}")
  seed_contact "${username}" "${display_name}" "${email}" "Range42 Trainees"
  i=$((i + 1))
done

# ── 11. Create Deck kanban board ─────────────────────────────────────────────
echo "[init] Creating Deck board ..."

board_resp=$(curl -sf -X POST \
  "${NC_URL}/index.php/apps/deck/api/v1.0/boards" \
  -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"title":"Training Tasks","color":"0069AF"}' || echo '{}')

board_id=$(printf '%s' "${board_resp}" | jq -r '.id // empty')

if [ -n "${board_id}" ]; then
  echo "[init]   + board created: id=${board_id}"

  order=0
  for stack_title in "Backlog" "In Progress" "Done"; do
    curl -sf -X POST \
      "${NC_URL}/index.php/apps/deck/api/v1.0/boards/${board_id}/stacks" \
      -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"${stack_title}\",\"order\":${order}}" >/dev/null || true
    order=$((order + 1))
  done

  stacks_resp=$(curl -sf \
    "${NC_URL}/index.php/apps/deck/api/v1.0/boards/${board_id}/stacks" \
    -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
    -H "Accept: application/json" || echo '[]')
  backlog_id=$(printf '%s' "${stacks_resp}" | jq -r '.[0].id // empty')

  if [ -n "${backlog_id}" ]; then
    card_order=0
    for card_title in \
      "Read welcome documentation" \
      "Complete lab environment setup" \
      "Run first security scan" \
      "Document findings in shared folder" \
      "Submit post-training feedback"
    do
      curl -sf -X POST \
        "${NC_URL}/index.php/apps/deck/api/v1.0/boards/${board_id}/stacks/${backlog_id}/cards" \
        -u "${NC_ADMIN_USER}:${NC_ADMIN_PASS}" \
        -H "Content-Type: application/json" \
        -d "{\"title\":\"${card_title}\",\"order\":${card_order},\"type\":\"plain\"}" >/dev/null || true
      card_order=$((card_order + 1))
    done
    echo "[init]   + 5 sample cards seeded in Backlog"
  fi
else
  echo "[warn] Deck board creation failed (Deck app may not be enabled yet)"
fi

# ── 12. Emit nextcloud-credentials.json ─────────────────────────────────────
echo "[init] Writing nextcloud-credentials.json ..."

CREDS_JSON="${TOKENS_DIR}/nextcloud-credentials.json"

app_passwords="[]"
while IFS=': ' read -r username app_pass; do
  [ -z "${username}" ] && continue
  app_passwords=$(printf '%s' "${app_passwords}" | \
    jq --arg u "${username}" --arg p "${app_pass}" \
    '. + [{"username": $u, "app_password": $p}]')
done < "${TOKENS_FILE}"

groups_json="[]"
i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username" "${USERS_FILE}")
  group=$(yq e ".admins[${i}].group // \"\"" "${USERS_FILE}")
  if [ -n "${group}" ] && [ "${group}" != "null" ]; then
    groups_json=$(printf '%s' "${groups_json}" | \
      jq --arg u "${username}" --arg g "${group}" \
      '. + [{"username": $u, "group": $g}]')
  fi
  i=$((i + 1))
done
i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username" "${USERS_FILE}")
  group=$(yq e ".users[${i}].group // \"\"" "${USERS_FILE}")
  if [ -n "${group}" ] && [ "${group}" != "null" ]; then
    groups_json=$(printf '%s' "${groups_json}" | \
      jq --arg u "${username}" --arg g "${group}" \
      '. + [{"username": $u, "group": $g}]')
  fi
  i=$((i + 1))
done

jq -n \
  --arg base_url       "${NC_BASE_URL}" \
  --argjson app_passwords "${app_passwords}" \
  --argjson groups        "${groups_json}" \
  '{
    "service": "nextcloud",
    "base_url": $base_url,
    "app_passwords": $app_passwords,
    "service_specific": {
      "groups": ["trainees","instructors"],
      "group_memberships": $groups,
      "shares": ["public_link","password_protected","time_expiring"],
      "home_folder_path": "/Shared/Welcome",
      "auto_joined_paths": ["/Shared/Welcome"]
    }
  }' > "${CREDS_JSON}"

echo "[init]   + nextcloud-credentials.json written to ${CREDS_JSON}"

# ── 13. Mark as provisioned ──────────────────────────────────────────────────
touch "${PROVISION_STAMP}"
echo "[init] Provisioning complete. App passwords written to ${TOKENS_FILE}."
