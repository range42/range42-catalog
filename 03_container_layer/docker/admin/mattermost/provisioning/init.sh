#!/usr/bin/env sh
#
# ISSUE 143 / ISSUE 173
#
# Bootstrap script for the Mattermost provisioner sidecar.
# Runs once after Mattermost is healthy; guarded by a stamp file for idempotency.
#
# User declarations come from USERS_FILE (default: /provisioning/users.yml).
# All users are created via the Mattermost REST API (POST /api/v4/users).
# The first admin is created without auth — Mattermost auto-grants system_admin
# when no system admin exists yet (requires MM_TEAMSETTINGS_ENABLEOPENSERVER=true).
# Personal access tokens are generated via the Mattermost REST API.
# Tokens written to /tokens/tokens.txt; full credentials to /tokens/mattermost-credentials.json.
#
set -eu

MM_URL="${MM_URL:-http://mattermost:8065}"
MM_ADMIN_USER="${MM_ADMIN_USER:-admin}"
MM_ADMIN_PASS="${MM_ADMIN_PASS:-Admin1234!}"
MM_TEAM_NAME="${MM_TEAM_NAME:-range42}"
MM_TEAMS="${MM_TEAMS:-}"
MM_BASE_URL="${MM_BASE_URL:-https://localhost:8065}"
GITEA_URL="${GITEA_URL:-}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-}"
USERS_FILE="${USERS_FILE:-/provisioning/users.yml}"
PROVISION_STAMP="/tokens/.provisioned"
TOKENS_FILE="/tokens/tokens.txt"
CREDS_FILE="/tokens/mattermost-credentials.json"

# Variables populated by provisioning sections; initialised here for set -u safety
bot_username="r42bot"
bot_token=""
incoming_webhook_url=""
team_defs=0

# ── Helpers ──────────────────────────────────────────────────────────────────

get_user_id() {
  curl -sf "${MM_URL}/api/v4/users/username/${1}" \
    -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty'
}

get_or_create_team() {
  local name="$1" display_name="$2"
  local resp t_id
  resp=$(curl -s -X POST "${MM_URL}/api/v4/teams" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg n "$name" --arg dn "$display_name" \
      '{"name":$n,"display_name":$dn,"type":"O"}')") || true
  t_id=$(printf '%s' "$resp" | jq -r '.id // empty')
  if [ -z "$t_id" ]; then
    t_id=$(curl -sf "${MM_URL}/api/v4/teams/name/${name}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty') || true
  fi
  printf '%s' "$t_id"
}

get_or_create_channel() {
  local team_id="$1" name="$2" display_name="$3"
  local resp c_id attempt err_msg
  attempt=0
  while [ "$attempt" -lt 3 ]; do
    resp=$(curl -s -X POST "${MM_URL}/api/v4/channels" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg tid "$team_id" --arg n "$name" --arg dn "$display_name" \
        '{"team_id":$tid,"name":$n,"display_name":$dn,"type":"O"}')") || true
    c_id=$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)
    [ -n "$c_id" ] && break
    c_id=$(curl -sf "${MM_URL}/api/v4/teams/${team_id}/channels/name/${name}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty' 2>/dev/null || true) || true
    [ -n "$c_id" ] && break
    attempt=$((attempt + 1))
    if [ "$attempt" -lt 3 ]; then
      err_msg=$(printf '%s' "$resp" | jq -r '.message // "no response"' 2>/dev/null || echo "no response")
      echo "[warn]   #${name}: attempt ${attempt} failed (${err_msg}), retrying in 3s ..."
      sleep 3
    fi
  done
  printf '%s' "$c_id"
}

add_user_to_team() {
  local uid="$1" tid="$2"
  curl -s -X POST "${MM_URL}/api/v4/teams/${tid}/members" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg uid "$uid" --arg tid "$tid" '{"team_id":$tid,"user_id":$uid}')" \
    >/dev/null || true
}

add_user_to_channel() {
  local uid="$1" cid="$2"
  curl -s -X POST "${MM_URL}/api/v4/channels/${cid}/members" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg uid "$uid" '{"user_id":$uid}')" \
    >/dev/null || true
}

post_and_pin() {
  local channel_id="$1" message="$2"
  local post_id
  post_id=$(curl -sf -X POST "${MM_URL}/api/v4/posts" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg cid "$channel_id" --arg msg "$message" \
      '{"channel_id":$cid,"message":$msg}')" | jq -r '.id // empty') || true
  if [ -n "$post_id" ]; then
    curl -sf -X POST "${MM_URL}/api/v4/posts/${post_id}/pin" \
      -H "Authorization: Bearer ${admin_token}" >/dev/null || true
  fi
}

# Resolve channel_id from the channel_map temp file, falling back to API lookup.
# Args: team_name channel_name team_id
channel_id_for() {
  local t_name="$1" ch_name="$2" t_id="$3"
  local c_id
  c_id=$(grep "^${t_name}:${ch_name}:" /tmp/channel_map.txt 2>/dev/null | head -1 | cut -d: -f3 || true)
  if [ -z "$c_id" ] && [ -n "$t_id" ]; then
    c_id=$(curl -sf "${MM_URL}/api/v4/teams/${t_id}/channels/name/${ch_name}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty') || true
  fi
  printf '%s' "$c_id"
}

# ── 1. Wait for Mattermost HTTP (max 180 s) ───────────────────────────────────
echo "[init] Waiting for Mattermost at ${MM_URL} ..."
attempts=0
until curl -sf "${MM_URL}/api/v4/system/ping" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 60 ]; then
    echo "[fatal] Mattermost did not become healthy after 180 s. Aborting."
    exit 1
  fi
  sleep 3
done
echo "[init] Mattermost is up — waiting 15 s for bundled plugins to initialize ..."
sleep 15
echo "[init] Plugin warmup done."

# ── 2. Idempotency guard ──────────────────────────────────────────────────────
if [ -f "${PROVISION_STAMP}" ]; then
  echo "[init] Already provisioned (stamp found at ${PROVISION_STAMP}). Exiting."
  exit 0
fi

# ── 3. Admin users (REST API — no auth; first user auto-gets system_admin) ────
# Mattermost grants system_admin to the first account created when no
# system admin exists yet, provided MM_TEAMSETTINGS_ENABLEOPENSERVER=true.
admin_count=$(yq e '.admins | length' "${USERS_FILE}")
echo "[init] Creating ${admin_count} admin user(s) ..."

i=0
while [ "${i}" -lt "${admin_count}" ]; do
  username=$(yq e ".admins[${i}].username" "${USERS_FILE}")
  email=$(yq e ".admins[${i}].email"       "${USERS_FILE}")
  password=$(yq e ".admins[${i}].password" "${USERS_FILE}")

  echo "[init]   + admin: ${username}"
  create_resp=$(curl -s -X POST "${MM_URL}/api/v4/users" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "${email}" --arg u "${username}" --arg p "${password}" \
          '{"email":$e,"username":$u,"password":$p}')")
  created_id=$(printf '%s' "${create_resp}" | jq -r '.id // empty')
  if [ -n "${created_id}" ]; then
    echo "[init]   created ${username} (id=${created_id})"
  else
    echo "[warn] ${username} may already exist — skipping"
  fi

  i=$((i + 1))
done

# ── 4. Login as admin via REST API ────────────────────────────────────────────
echo "[init] Logging in as admin (${MM_ADMIN_USER}) ..."
mm_token=""
attempts=0
until [ -n "${mm_token}" ] && [ "${mm_token}" != "null" ]; do
  attempts=$((attempts + 1))
  if [ "${attempts}" -ge 20 ]; then
    echo "[fatal] Could not log in as admin after 60 s"
    exit 1
  fi
  auth_resp=$(curl -sf -D - -X POST "${MM_URL}/api/v4/users/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "${MM_ADMIN_USER}" --arg p "${MM_ADMIN_PASS}" '{"login_id":$u,"password":$p}')" 2>/dev/null || echo "")
  mm_token=$(echo "${auth_resp}" | grep -i '^Token:' | awk '{print $2}' | tr -d '\r')
  [ -z "${mm_token}" ] && sleep 3
done

auth_response="${auth_resp}"
admin_token="${mm_token}"
admin_user=$(printf '%s' "${auth_response}" | tail -1)
admin_id=$(printf '%s' "${admin_user}" | jq -r '.id')

if [ -z "${admin_token}" ] || [ "${admin_id}" = "null" ]; then
  echo "[fatal] Could not obtain admin session token. Aborting."
  exit 1
fi
echo "[init] Admin session established (id=${admin_id})."

# Upgrade from ephemeral session token to a personal access token (PAT).
# Session tokens can be silently invalidated by Mattermost internal config
# reloads that occur during startup; PATs are database-stored and survive them.
_pat_resp=$(curl -sf -X POST "${MM_URL}/api/v4/users/${admin_id}/tokens" \
  -H "Authorization: Bearer ${admin_token}" \
  -H "Content-Type: application/json" \
  -d '{"description":"Provisioner internal token"}') || true
_pat_tok=$(printf '%s' "$_pat_resp" | jq -r '.token // empty')
if [ -n "$_pat_tok" ]; then
  admin_token="$_pat_tok"
  echo "[init] Switched to personal access token for provisioning operations."
fi

# ── 5. Regular users (REST API with admin token) ──────────────────────────────
user_count=$(yq e '.users | length' "${USERS_FILE}")
echo "[init] Creating ${user_count} regular user(s) ..."

i=0
while [ "${i}" -lt "${user_count}" ]; do
  username=$(yq e ".users[${i}].username" "${USERS_FILE}")
  email=$(yq e ".users[${i}].email"       "${USERS_FILE}")
  password=$(yq e ".users[${i}].password" "${USERS_FILE}")

  echo "[init]   + user: ${username}"
  create_resp=$(curl -s -X POST "${MM_URL}/api/v4/users" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "${email}" --arg u "${username}" --arg p "${password}" \
          '{"email":$e,"username":$u,"password":$p}')")
  created_id=$(printf '%s' "${create_resp}" | jq -r '.id // empty')
  if [ -n "${created_id}" ]; then
    echo "[init]   created ${username} (id=${created_id})"
  else
    echo "[warn] ${username} may already exist — skipping"
  fi

  i=$((i + 1))
done

# ── 6. Create default team ────────────────────────────────────────────────────
echo "[init] Creating default team '${MM_TEAM_NAME}' ..."
team_resp=$(curl -sf -X POST "${MM_URL}/api/v4/teams" \
  -H "Authorization: Bearer ${admin_token}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg n "${MM_TEAM_NAME}" --arg dn "Range42" \
    '{"name":$n,"display_name":$dn,"type":"O"}')") \
  || true
team_id=$(printf '%s' "${team_resp}" | jq -r '.id // empty')
if [ -z "${team_id}" ]; then
  team_id=$(curl -sf "${MM_URL}/api/v4/teams/name/${MM_TEAM_NAME}" \
    -H "Authorization: Bearer ${admin_token}" | jq -r '.id')
fi
echo "[init] Default team id=${team_id}."

# ── 7. Add all users to default team ─────────────────────────────────────────
add_to_team() {
  local section="${1}"
  local count j uname uid

  count=$(yq e ".${section} | length" "${USERS_FILE}")
  j=0
  while [ "${j}" -lt "${count}" ]; do
    uname=$(yq e ".${section}[${j}].username" "${USERS_FILE}")
    uid=$(curl -sf "${MM_URL}/api/v4/users/username/${uname}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id')

    echo "[init]   + team member: ${uname} (${uid})"
    curl -sf -X POST "${MM_URL}/api/v4/teams/${team_id}/members" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg uid "${uid}" --arg tid "${team_id}" \
        '{"team_id":$tid,"user_id":$uid}')" \
      >/dev/null \
      || echo "[warn] Could not add ${uname} to team — may already be a member"

    j=$((j + 1))
  done
}

echo "[init] Adding users to default team '${MM_TEAM_NAME}' ..."
add_to_team admins
add_to_team users

# ── 8. Generate personal access tokens for all users ─────────────────────────
echo "[init] Generating personal access tokens ..."
: > "${TOKENS_FILE}"

generate_tokens() {
  local section="${1}"
  local count j uname uid token_val

  count=$(yq e ".${section} | length" "${USERS_FILE}")
  j=0
  while [ "${j}" -lt "${count}" ]; do
    uname=$(yq e ".${section}[${j}].username" "${USERS_FILE}")
    uid=$(curl -sf "${MM_URL}/api/v4/users/username/${uname}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id')

    token_resp=$(curl -sf -X POST "${MM_URL}/api/v4/users/${uid}/tokens" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n '{"description":"API access token"}')")
    token_val=$(printf '%s' "${token_resp}" | jq -r '.token // empty')

    if [ -n "${token_val}" ]; then
      printf '%s:%s\n' "${uname}" "${token_val}" >> "${TOKENS_FILE}"
      echo "[init]   + token generated for ${uname}"
    else
      echo "[warn] Could not create token for ${uname}"
    fi

    j=$((j + 1))
  done
}

generate_tokens admins
generate_tokens users

# ── 9. Gitea SSO setup ────────────────────────────────────────────────────────
# Registers Mattermost as an OAuth2 application in Gitea and enables the
# built-in "GitLab" SSO provider in Mattermost.  Skipped when GITEA_URL is unset.
if [ -n "${GITEA_URL}" ] && [ -n "${GITEA_ADMIN_PASS}" ]; then
  echo "[init] Registering Mattermost as OAuth2 app in Gitea (${GITEA_URL}) ..."
  oauth_resp=$(curl -sf -X POST "${GITEA_URL}/api/v1/user/applications/oauth2" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg n "mattermost-sso" --arg cb "${MM_BASE_URL}/signup/gitlab/complete" \
      '{"name":$n,"redirect_uris":[$cb],"confidential_client":true}')") || true
  gitea_client_id=$(printf '%s' "${oauth_resp}" | jq -r '.client_id // empty')
  gitea_client_secret=$(printf '%s' "${oauth_resp}" | jq -r '.client_secret // empty')

  if [ -n "${gitea_client_id}" ]; then
    echo "[init] Gitea OAuth2 app created (client_id=${gitea_client_id})"
    curl -sf -X PUT "${MM_URL}/api/v4/config/patch" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg cid  "${gitea_client_id}" \
        --arg csec "${gitea_client_secret}" \
        --arg auth "${GITEA_URL}/login/oauth/authorize" \
        --arg tok  "${GITEA_URL}/login/oauth/access_token" \
        --arg api  "${GITEA_URL}/api/v1/user" \
        '{"GitLabSettings":{"Enable":true,"Id":$cid,"Secret":$csec,
           "AuthEndpoint":$auth,"TokenEndpoint":$tok,"UserApiEndpoint":$api}}')" \
      >/dev/null || echo "[warn] Could not configure Mattermost GitLab SSO settings"
    echo "[init] Mattermost SSO configured for Gitea."
  else
    echo "[warn] Could not register OAuth2 app in Gitea — SSO skipped."
  fi
else
  echo "[init] GITEA_URL or GITEA_ADMIN_PASS not set — skipping SSO setup."
fi

# ── 10. Predefined teams + channels from users.yml teams[] ───────────────────
echo "[init] Creating predefined teams and channels ..."
: > /tmp/channel_map.txt
: > /tmp/team_map.txt

team_defs=$(yq e '.teams | length' "${USERS_FILE}" 2>/dev/null || echo "0")
ti=0
while [ "${ti}" -lt "${team_defs}" ]; do
  t_name=$(yq e ".teams[${ti}].name"         "${USERS_FILE}")
  t_disp=$(yq e ".teams[${ti}].display_name" "${USERS_FILE}")
  t_id=$(get_or_create_team "$t_name" "$t_disp")
  echo "[init]   team: ${t_name} (id=${t_id})"
  printf '%s:%s\n' "$t_name" "$t_id" >> /tmp/team_map.txt

  # Admins join every predefined team; regular users join trainees + incidents.
  admin_cnt=$(yq e '.admins | length' "${USERS_FILE}")
  ai=0
  while [ "${ai}" -lt "${admin_cnt}" ]; do
    adm_name=$(yq e ".admins[${ai}].username" "${USERS_FILE}")
    adm_id=$(get_user_id "$adm_name")
    add_user_to_team "$adm_id" "$t_id"
    ai=$((ai + 1))
  done

  if [ "$t_name" = "trainees" ] || [ "$t_name" = "incidents" ]; then
    uc=$(yq e '.users | length' "${USERS_FILE}")
    ui=0
    while [ "${ui}" -lt "${uc}" ]; do
      uname=$(yq e ".users[${ui}].username" "${USERS_FILE}")
      uid=$(get_user_id "$uname")
      add_user_to_team "$uid" "$t_id"
      ui=$((ui + 1))
    done
  fi

  # Create channels for this team.
  ch_count=$(yq e ".teams[${ti}].channels | length" "${USERS_FILE}" 2>/dev/null || echo "0")
  ci=0
  while [ "${ci}" -lt "${ch_count}" ]; do
    ch_name=$(yq e ".teams[${ti}].channels[${ci}].name"         "${USERS_FILE}")
    ch_disp=$(yq e ".teams[${ti}].channels[${ci}].display_name" "${USERS_FILE}")
    ch_id=$(get_or_create_channel "$t_id" "$ch_name" "$ch_disp")
    echo "[init]     channel: #${ch_name} (id=${ch_id})"
    printf '%s:%s:%s\n' "$t_name" "$ch_name" "$ch_id" >> /tmp/channel_map.txt
    ci=$((ci + 1))
  done

  ti=$((ti + 1))
done

# ── 11. Player-team channels in main team ─────────────────────────────────────
# MM_TEAMS=team-blue,team-red — one dedicated channel per player team.
echo "[init] Creating player-team channels in '${MM_TEAM_NAME}' ..."
if [ -n "${MM_TEAMS}" ]; then
  IFS=','
  for pt in ${MM_TEAMS}; do
    IFS=' '
    pt_disp=$(printf '%s' "$pt" | tr '-' ' ')
    pt_cid=$(get_or_create_channel "$team_id" "$pt" "$pt_disp")
    echo "[init]   player-team channel: #${pt} (id=${pt_cid})"
    printf '%s:%s:%s\n' "${MM_TEAM_NAME}" "$pt" "$pt_cid" >> /tmp/channel_map.txt
    IFS=','
  done
  IFS=' '
fi

# ── 12. Auto-join users to their player-team channel ─────────────────────────
echo "[init] Auto-joining users to player-team channels ..."
uc=$(yq e '.users | length' "${USERS_FILE}")
ui=0
while [ "${ui}" -lt "${uc}" ]; do
  uname=$(yq e ".users[${ui}].username" "${USERS_FILE}")
  pt=$(yq e ".users[${ui}].player_team // \"\"" "${USERS_FILE}" 2>/dev/null || true)
  if [ -n "$pt" ] && [ "$pt" != "null" ]; then
    uid=$(get_user_id "$uname")
    pt_cid=$(channel_id_for "${MM_TEAM_NAME}" "$pt" "$team_id")
    if [ -n "$pt_cid" ]; then
      add_user_to_channel "$uid" "$pt_cid"
      echo "[init]   ${uname} -> #${pt}"
    fi
  fi
  ui=$((ui + 1))
done

# ── 13. Bot account ───────────────────────────────────────────────────────────
echo "[init] Creating bot account ..."
bot_username=$(yq e '.bot.username // "r42bot"'            "${USERS_FILE}" 2>/dev/null || echo "r42bot")
bot_display=$(yq e  '.bot.display_name // "Range42 Bot"'   "${USERS_FILE}" 2>/dev/null || echo "Range42 Bot")
bot_desc=$(yq e     '.bot.description // "Training bot"'   "${USERS_FILE}" 2>/dev/null || echo "Training bot")

bot_id=""
bot_attempt=0
while [ -z "$bot_id" ] && [ "$bot_attempt" -lt 3 ]; do
  bot_resp=$(curl -s -X POST "${MM_URL}/api/v4/bots" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$bot_username" --arg dn "$bot_display" --arg d "$bot_desc" \
      '{"username":$u,"display_name":$dn,"description":$d}')") || true
  bot_id=$(printf '%s' "$bot_resp" | jq -r '.user_id // empty' 2>/dev/null || true)
  if [ -z "$bot_id" ]; then
    bot_id=$(curl -sf "${MM_URL}/api/v4/users/username/${bot_username}" \
      -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty' 2>/dev/null || true) || true
  fi
  if [ -z "$bot_id" ]; then
    bot_attempt=$((bot_attempt + 1))
    if [ "$bot_attempt" -lt 3 ]; then
      err_msg=$(printf '%s' "$bot_resp" | jq -r '.message // "no response"' 2>/dev/null || echo "no response")
      echo "[warn] Bot attempt ${bot_attempt} failed (${err_msg}), retrying in 3s ..."
      sleep 3
    fi
  fi
done

if [ -n "$bot_id" ]; then
  add_user_to_team "$bot_id" "$team_id"
  bot_tok_resp=$(curl -sf -X POST "${MM_URL}/api/v4/users/${bot_id}/tokens" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n '{"description":"Bot API token"}')") || true
  bot_token=$(printf '%s' "$bot_tok_resp" | jq -r '.token // empty')
  if [ -n "$bot_token" ]; then
    printf 'bot:%s\n' "${bot_token}" >> "${TOKENS_FILE}"
    echo "[init] Bot account ready (id=${bot_id}), token saved."
  else
    echo "[warn] Bot created but token generation failed."
  fi
else
  echo "[warn] Could not create bot account — is MM_SERVICESETTINGS_ENABLEBOTACCOUNTCREATION=true?"
fi

# ── 14. Webhooks ──────────────────────────────────────────────────────────────
echo "[init] Creating webhooks ..."

wh_count=$(yq e '.incoming_webhooks | length' "${USERS_FILE}" 2>/dev/null || echo "0")
wi=0
while [ "${wi}" -lt "${wh_count}" ]; do
  wh_disp=$(yq e ".incoming_webhooks[${wi}].display_name" "${USERS_FILE}")
  wh_desc=$(yq e ".incoming_webhooks[${wi}].description"  "${USERS_FILE}")
  wh_team=$(yq e ".incoming_webhooks[${wi}].team"         "${USERS_FILE}")
  wh_chan=$(yq e ".incoming_webhooks[${wi}].channel"       "${USERS_FILE}")

  wh_tid=$(curl -sf "${MM_URL}/api/v4/teams/name/${wh_team}" \
    -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty') || true
  [ -z "$wh_tid" ] && wh_tid="$team_id"
  wh_cid=$(channel_id_for "$wh_team" "$wh_chan" "$wh_tid")

  if [ -n "$wh_cid" ]; then
    wh_resp=$(curl -sf -X POST "${MM_URL}/api/v4/hooks/incoming" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg cid "$wh_cid" --arg dn "$wh_disp" --arg d "$wh_desc" \
        '{"channel_id":$cid,"display_name":$dn,"description":$d}')") || true
    wh_id=$(printf '%s' "$wh_resp" | jq -r '.id // empty')
    if [ -n "$wh_id" ]; then
      incoming_webhook_url="${MM_BASE_URL}/hooks/${wh_id}"
      printf 'webhook_incoming:%s\n' "${incoming_webhook_url}" >> "${TOKENS_FILE}"
      echo "[init]   incoming webhook '${wh_disp}' -> ${incoming_webhook_url}"

      # Register as system webhook in Gitea so repo events flow into Mattermost.
      if [ -n "${GITEA_URL}" ] && [ -n "${GITEA_ADMIN_PASS}" ]; then
        curl -s -X POST "${GITEA_URL}/api/v1/admin/hooks" \
          -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
          -H "Content-Type: application/json" \
          -d "$(jq -n \
            --arg url "${incoming_webhook_url}" \
            '{"type":"slack","active":true,"events":["push","pull_request","issues"],
              "config":{"url":$url,"content_type":"json"}}')" \
          >/dev/null \
          || echo "[warn] Could not register Gitea system webhook — check credentials"
        echo "[init]   Gitea system webhook -> MM registered."
      fi
    fi
  fi
  wi=$((wi + 1))
done

owh_count=$(yq e '.outgoing_webhooks | length' "${USERS_FILE}" 2>/dev/null || echo "0")
owi=0
while [ "${owi}" -lt "${owh_count}" ]; do
  owh_disp=$(yq e ".outgoing_webhooks[${owi}].display_name" "${USERS_FILE}")
  owh_desc=$(yq e ".outgoing_webhooks[${owi}].description"  "${USERS_FILE}")
  owh_team=$(yq e ".outgoing_webhooks[${owi}].team"         "${USERS_FILE}")
  owh_chan=$(yq e ".outgoing_webhooks[${owi}].channel"       "${USERS_FILE}")
  owh_cb=$(yq e   ".outgoing_webhooks[${owi}].callback_url" "${USERS_FILE}")
  owh_tw_count=$(yq e ".outgoing_webhooks[${owi}].trigger_words | length" "${USERS_FILE}" 2>/dev/null || echo "0")
  owh_tw_json="[]"
  if [ "$owh_tw_count" -gt 0 ]; then
    owh_tw_json=$(yq e ".outgoing_webhooks[${owi}].trigger_words[]" "${USERS_FILE}" | jq -R . | jq -s .)
  fi

  owh_tid=$(curl -sf "${MM_URL}/api/v4/teams/name/${owh_team}" \
    -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty') || true
  [ -z "$owh_tid" ] && owh_tid="$team_id"
  owh_cid=$(channel_id_for "$owh_team" "$owh_chan" "$owh_tid")

  if [ -n "$owh_cid" ]; then
    if curl -sf -X POST "${MM_URL}/api/v4/hooks/outgoing" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n \
        --arg tid "$owh_tid" \
        --arg cid "$owh_cid" \
        --arg dn  "$owh_disp" \
        --arg d   "$owh_desc" \
        --argjson tw "$owh_tw_json" \
        --arg cb  "$owh_cb" \
        '{"team_id":$tid,"channel_id":$cid,"display_name":$dn,"description":$d,
          "trigger_words":$tw,"callback_urls":[$cb],"content_type":"application/json"}')" \
      >/dev/null 2>&1; then
      echo "[init]   outgoing webhook '${owh_disp}' created."
    else
      echo "[warn] Could not create outgoing webhook '${owh_disp}'"
    fi
  fi
  owi=$((owi + 1))
done

# ── 15. Read-only channel moderation ──────────────────────────────────────────
echo "[init] Applying read-only moderation where declared ..."
ti=0
while [ "${ti}" -lt "${team_defs}" ]; do
  t_name=$(yq e ".teams[${ti}].name" "${USERS_FILE}")
  t_id=$(grep "^${t_name}:" /tmp/team_map.txt | head -1 | cut -d: -f2 || true)
  ch_count=$(yq e ".teams[${ti}].channels | length" "${USERS_FILE}" 2>/dev/null || echo "0")
  ci=0
  while [ "${ci}" -lt "${ch_count}" ]; do
    ro=$(yq e ".teams[${ti}].channels[${ci}].readonly // false" "${USERS_FILE}")
    if [ "$ro" = "true" ]; then
      ch_name=$(yq e ".teams[${ti}].channels[${ci}].name" "${USERS_FILE}")
      ch_id=$(channel_id_for "$t_name" "$ch_name" "$t_id")
      if [ -n "$ch_id" ]; then
        if curl -sf -X PUT "${MM_URL}/api/v4/channels/${ch_id}/moderations" \
          -H "Authorization: Bearer ${admin_token}" \
          -H "Content-Type: application/json" \
          -d '[
            {"name":"create_post",         "roles":{"members":{"value":false,"enabled":true},"guests":{"value":false,"enabled":true}}},
            {"name":"add_reaction",         "roles":{"members":{"value":false,"enabled":true},"guests":{"value":false,"enabled":true}}},
            {"name":"manage_members",       "roles":{"members":{"value":false,"enabled":true}}},
            {"name":"use_channel_mentions", "roles":{"members":{"value":false,"enabled":true},"guests":{"value":false,"enabled":true}}}
          ]' >/dev/null 2>&1; then
          echo "[init]   read-only: #${t_name}/#${ch_name}"
        else
          echo "[info]   read-only moderation skipped for #${ch_name} (requires Enterprise license)"
        fi
      fi
    fi
    ci=$((ci + 1))
  done
  ti=$((ti + 1))
done

# ── 16. Channel sidebar categories ────────────────────────────────────────────
# Create per-user per-team sidebar categories grouping channels by their
# declared category field (Training / Tools / Social).
echo "[init] Creating channel sidebar categories ..."

create_sidebar_categories_for_user() {
  local uid="$1" t_idx="$2" t_id="$3"
  local t_name n_channels category ch_name ch_id

  t_name=$(yq e ".teams[${t_idx}].name" "${USERS_FILE}")
  n_channels=$(yq e ".teams[${t_idx}].channels | length" "${USERS_FILE}" 2>/dev/null || echo "0")

  # Collect unique category names for this team.
  local cat_list
  cat_list=$(yq e ".teams[${t_idx}].channels[].category // \"General\"" "${USERS_FILE}" 2>/dev/null \
    | sort -u || true)

  for category in ${cat_list}; do
    local cids_json ci this_cat
    cids_json="[]"
    ci=0
    while [ "$ci" -lt "$n_channels" ]; do
      this_cat=$(yq e ".teams[${t_idx}].channels[${ci}].category // \"General\"" "${USERS_FILE}")
      if [ "$this_cat" = "$category" ]; then
        ch_name=$(yq e ".teams[${t_idx}].channels[${ci}].name" "${USERS_FILE}")
        ch_id=$(channel_id_for "$t_name" "$ch_name" "$t_id")
        if [ -n "$ch_id" ]; then
          cids_json=$(printf '%s' "$cids_json" | jq --arg id "$ch_id" '. + [$id]')
        fi
      fi
      ci=$((ci + 1))
    done

    curl -s -X POST \
      "${MM_URL}/api/v4/users/${uid}/teams/${t_id}/channels/categories" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg dn "$category" --argjson cids "$cids_json" \
        '{"display_name":$dn,"type":"custom","channel_ids":$cids}')" \
      >/dev/null || true
  done
}

ti=0
while [ "${ti}" -lt "${team_defs}" ]; do
  t_id=$(grep "^$(yq e ".teams[${ti}].name" "${USERS_FILE}"):" /tmp/team_map.txt \
    | head -1 | cut -d: -f2 || true)
  [ -z "$t_id" ] && { ti=$((ti + 1)); continue; }

  # Admins get categories in every team.
  admin_cnt=$(yq e '.admins | length' "${USERS_FILE}")
  ai=0
  while [ "${ai}" -lt "${admin_cnt}" ]; do
    adm=$(yq e ".admins[${ai}].username" "${USERS_FILE}")
    aid=$(get_user_id "$adm")
    [ -n "$aid" ] && create_sidebar_categories_for_user "$aid" "$ti" "$t_id"
    ai=$((ai + 1))
  done

  # Regular users get categories in trainees + incidents.
  t_name=$(yq e ".teams[${ti}].name" "${USERS_FILE}")
  if [ "$t_name" = "trainees" ] || [ "$t_name" = "incidents" ]; then
    uc=$(yq e '.users | length' "${USERS_FILE}")
    ui=0
    while [ "${ui}" -lt "${uc}" ]; do
      uname=$(yq e ".users[${ui}].username" "${USERS_FILE}")
      uid=$(get_user_id "$uname")
      [ -n "$uid" ] && create_sidebar_categories_for_user "$uid" "$ti" "$t_id"
      ui=$((ui + 1))
    done
  fi

  ti=$((ti + 1))
done
echo "[init] Sidebar categories done."

# ── 17. Pin welcome messages ──────────────────────────────────────────────────
echo "[init] Pinning welcome messages to channels ..."
ti=0
while [ "${ti}" -lt "${team_defs}" ]; do
  t_name=$(yq e ".teams[${ti}].name" "${USERS_FILE}")
  t_id=$(grep "^${t_name}:" /tmp/team_map.txt | head -1 | cut -d: -f2 || true)
  ch_count=$(yq e ".teams[${ti}].channels | length" "${USERS_FILE}" 2>/dev/null || echo "0")
  ci=0
  while [ "${ci}" -lt "${ch_count}" ]; do
    pin_msg=$(yq e ".teams[${ti}].channels[${ci}].pinned_message // \"\"" "${USERS_FILE}" 2>/dev/null || true)
    if [ -n "$pin_msg" ] && [ "$pin_msg" != "null" ]; then
      ch_name=$(yq e ".teams[${ti}].channels[${ci}].name" "${USERS_FILE}")
      ch_id=$(channel_id_for "$t_name" "$ch_name" "$t_id")
      if [ -n "$ch_id" ]; then
        post_and_pin "$ch_id" "$pin_msg"
        echo "[init]   pinned: ${t_name}/#${ch_name}"
      fi
    fi
    ci=$((ci + 1))
  done
  ti=$((ti + 1))
done

# ── 18. System configuration ──────────────────────────────────────────────────
echo "[init] Applying system configuration ..."
curl -sf -X PUT "${MM_URL}/api/v4/config/patch" \
  -H "Authorization: Bearer ${admin_token}" \
  -H "Content-Type: application/json" \
  -d '{
    "FileSettings": {
      "EnableFileAttachments": true,
      "MaxFileSize": 52428800,
      "AllowedFileExtensions": ".jpg,.jpeg,.png,.gif,.pdf,.txt,.md,.zip,.tar.gz,.log,.csv,.json,.yaml,.yml,.pcap"
    },
    "ServiceSettings": {
      "EnableBotAccountCreation": true
    },
    "TeamSettings": {
      "SiteName": "Range42",
      "DefaultChannels": ["town-square","off-topic"]
    }
  }' >/dev/null || echo "[warn] Could not apply system configuration patch"
echo "[init] System configuration applied."
echo "[info] Custom branding (logo, login page text) requires Enterprise license — skipped."

# ── 19. Enable plugins (Playbooks, Calls) and create sample playbook ─────────
echo "[init] Enabling plugins ..."
for plugin_id in playbooks com.mattermost.calls; do
  curl -s -X POST "${MM_URL}/api/v4/plugins/${plugin_id}/enable" \
    -H "Authorization: Bearer ${admin_token}" \
    >/dev/null || echo "[warn] Could not enable plugin '${plugin_id}'"
  echo "[init]   plugin enabled: ${plugin_id}"
done

# Retry playbook creation until the Playbooks plugin POST API is ready.
# The GET endpoint responds before the POST handler is registered, so polling
# GET first is insufficient — retry the creation itself.
echo "[init] Creating sample playbook (retrying until Playbooks plugin POST is ready) ..."
playbook_json=$(jq -n --arg tid "$team_id" '{
  "title": "Incident Response Runbook",
  "team_id": $tid,
  "description": "Step-by-step guide for incident response during training exercises.",
  "public": true,
  "checklists": [
    {
      "title": "Identification",
      "items": [
        {"title": "Detect the incident from alerts in #soc-alerts"},
        {"title": "Classify incident severity (P1 / P2 / P3)"},
        {"title": "Notify on-call team and open an incident channel"}
      ]
    },
    {
      "title": "Containment",
      "items": [
        {"title": "Isolate affected systems from the network"},
        {"title": "Preserve evidence (logs, memory dumps, pcaps)"},
        {"title": "Block attacker IPs / domains at the perimeter"}
      ]
    },
    {
      "title": "Eradication and Recovery",
      "items": [
        {"title": "Remove malicious artifacts from all affected hosts"},
        {"title": "Patch the exploited vulnerability"},
        {"title": "Restore services from a known-good backup"}
      ]
    },
    {
      "title": "Post-Incident",
      "items": [
        {"title": "Write post-mortem in #postmortem (5 Whys format)"},
        {"title": "Update this runbook with lessons learned"},
        {"title": "Close incident declaration and debrief the team in #incidents/general"}
      ]
    }
  ]
}')
pb_created=0
pb_attempt=0
while [ "$pb_attempt" -lt 20 ] && [ "$pb_created" -eq 0 ]; do
  playbook_resp=$(curl -s -X POST "${MM_URL}/plugins/playbooks/api/v0/playbooks" \
    -H "Authorization: Bearer ${admin_token}" \
    -H "Content-Type: application/json" \
    -d "$playbook_json") || true
  playbook_id=$(printf '%s' "$playbook_resp" | jq -r '.id // empty')
  if [ -n "$playbook_id" ]; then
    pb_created=1
    echo "[init] Playbook 'Incident Response Runbook' created (id=${playbook_id})"
  else
    pb_attempt=$((pb_attempt + 1))
    sleep 3
  fi
done
if [ "$pb_created" -eq 0 ]; then
  echo "[warn] Playbooks plugin not ready or not installed — playbook creation skipped."
fi

# ── 20. Custom statuses ────────────────────────────────────────────────────────
# Mattermost does not support system-level custom status presets.
# Strategy: pin a status-guide message in the main team, and set each user's
# initial custom status to the first declared status in users.yml.
echo "[init] Setting up custom statuses ..."
cs_count=$(yq e '.custom_statuses | length' "${USERS_FILE}" 2>/dev/null || echo "0")
if [ "${cs_count}" -gt 0 ]; then
  town_sq_id=$(curl -sf "${MM_URL}/api/v4/teams/${team_id}/channels/name/town-square" \
    -H "Authorization: Bearer ${admin_token}" | jq -r '.id // empty') || true

  if [ -n "$town_sq_id" ]; then
    status_guide="**Available training custom statuses**\nSet via your avatar menu -> Set a custom status\n\n"
    idx=0
    while [ "${idx}" -lt "${cs_count}" ]; do
      cs_text=$(yq e ".custom_statuses[${idx}].text"  "${USERS_FILE}")
      cs_emoji=$(yq e ".custom_statuses[${idx}].emoji" "${USERS_FILE}")
      status_guide="${status_guide}:${cs_emoji}: **${cs_text}**\n"
      idx=$((idx + 1))
    done
    post_and_pin "$town_sq_id" "$(printf '%b' "$status_guide")"
    echo "[init] Custom status guide pinned in #town-square."
  fi

  first_text=$(yq e '.custom_statuses[0].text'  "${USERS_FILE}")
  first_emoji=$(yq e '.custom_statuses[0].emoji' "${USERS_FILE}")

  uc=$(yq e '.users | length' "${USERS_FILE}")
  ui=0
  while [ "${ui}" -lt "${uc}" ]; do
    uname=$(yq e ".users[${ui}].username" "${USERS_FILE}")
    uid=$(get_user_id "$uname")
    curl -s -X PUT "${MM_URL}/api/v4/users/${uid}/status/custom" \
      -H "Authorization: Bearer ${admin_token}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg e "$first_emoji" --arg t "$first_text" \
        '{"emoji":$e,"text":$t}')" \
      >/dev/null || true
    ui=$((ui + 1))
  done
  echo "[init] Initial custom status set for all users."
fi

# ── 21. Emit mattermost-credentials.json ─────────────────────────────────────
echo "[init] Writing credentials file ..."

# Build user tokens array from TOKENS_FILE (skip bot and webhook lines).
user_creds_json="[]"
while read -r line; do
  u="${line%%:*}"
  t="${line#*:}"
  case "$u" in
    bot|webhook_incoming) continue ;;
  esac
  user_creds_json=$(printf '%s' "$user_creds_json" | \
    jq --arg u "$u" --arg t "$t" '. + [{"username":$u,"token":$t}]')
done < "${TOKENS_FILE}" 2>/dev/null || true

# Build teams array from team_map.
teams_json="[]"
ti=0
while [ "${ti}" -lt "${team_defs}" ]; do
  t_n=$(yq e ".teams[${ti}].name" "${USERS_FILE}")
  t_id=$(grep "^${t_n}:" /tmp/team_map.txt | head -1 | cut -d: -f2 || true)
  teams_json=$(printf '%s' "$teams_json" | \
    jq --arg n "$t_n" --arg id "$t_id" '. + [{"name":$n,"id":$id}]')
  ti=$((ti + 1))
done

# Build channels array from channel_map.
channels_json="[]"
while IFS=: read -r t_n ch_n ch_id; do
  channels_json=$(printf '%s' "$channels_json" | \
    jq --arg t "$t_n" --arg n "$ch_n" --arg id "$ch_id" \
      '. + [{"team":$t,"channel":$n,"id":$id}]')
done < /tmp/channel_map.txt 2>/dev/null || true

# Build player_teams array.
pt_json="[]"
if [ -n "${MM_TEAMS}" ]; then
  IFS=','
  for pt in ${MM_TEAMS}; do
    IFS=' '
    pt_json=$(printf '%s' "$pt_json" | jq --arg p "$pt" '. + [$p]')
    IFS=','
  done
  IFS=' '
fi

jq -n \
  --arg  service       "mattermost" \
  --arg  url           "${MM_BASE_URL}" \
  --arg  admin_user    "${MM_ADMIN_USER}" \
  --arg  admin_pass    "${MM_ADMIN_PASS}" \
  --arg  bot_user      "${bot_username}" \
  --arg  bot_tok       "${bot_token}" \
  --arg  wh_url        "${incoming_webhook_url}" \
  --arg  main_team     "${MM_TEAM_NAME}" \
  --argjson user_creds   "${user_creds_json}" \
  --argjson teams        "${teams_json}" \
  --argjson channels     "${channels_json}" \
  --argjson player_teams "${pt_json}" \
  '{
    "service": $service,
    "url": $url,
    "admin": {"username": $admin_user, "password": $admin_pass},
    "service_specific": {
      "main_team": $main_team,
      "teams": $teams,
      "channels": $channels,
      "player_teams": $player_teams,
      "bot_account": {"username": $bot_user, "token": $bot_tok},
      "incoming_webhook_url": $wh_url,
      "auto_joined_channels": "each user is added to the channel matching their player_team value"
    },
    "user_tokens": $user_creds
  }' > "${CREDS_FILE}" || echo "[warn] Could not write ${CREDS_FILE}"
echo "[init] Credentials written to ${CREDS_FILE}."

# ── 22. Mark as provisioned ───────────────────────────────────────────────────
touch "${PROVISION_STAMP}"
echo "[init] Provisioning complete. Tokens: ${TOKENS_FILE}  Credentials: ${CREDS_FILE}"
