#!/usr/bin/env sh
#
# ISSUE 147 / ISSUE 175
#
# Rocket.Chat provisioner — users, teams, channels, bot, webhooks, credentials.
# Reads: $USERS_FILE (YAML with admins[], users[], teams[], channels[],
#                     auto_join[], bot, incoming_webhooks[], custom_statuses[])
# Writes:
#   /tokens/tokens.txt                   — username:token per line
#   /tokens/rocketchat-credentials.json  — full credentials for training-doc pipeline
#

set -eu

RC_URL="${RC_URL:-http://rocketchat:3000}"
RC_BASE_URL="${RC_BASE_URL:-https://localhost:3500}"
RC_ADMIN_USER="${RC_ADMIN_USER:-rc-admin}"
RC_ADMIN_PASS="${RC_ADMIN_PASS:-Admin1234!}"
RC_TEAMS="${RC_TEAMS:-}"
GITEA_URL="${GITEA_URL:-}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-}"
USERS_FILE="${USERS_FILE:-/provisioning/users.yml}"
TOKENS_FILE="/tokens/tokens.txt"
CREDS_FILE="/tokens/rocketchat-credentials.json"
STAMP_FILE="/tokens/.provisioned"
_CH_MAP="/tmp/rc_channel_map.txt"
_TEAM_MAP="/tmp/rc_team_map.txt"
bot_username="rc-bot"
bot_token=""
incoming_webhook_url=""

get_user_id() {
  curl -sf "${RC_URL}/api/v1/users.info?username=${1}" \
    -H "X-Auth-Token: ${rc_admin_token}" \
    -H "X-User-Id: ${rc_admin_id}" 2>/dev/null \
  | jq -r '.user._id // empty' || true
}

channel_id_for() {
  grep "^${1}:" "${_CH_MAP}" 2>/dev/null | head -1 | cut -d: -f2 || true
}

get_or_create_channel() {
  _cn="$1"; _ro="${2:-false}"
  _resp=$(curl -s -X POST "${RC_URL}/api/v1/channels.create" \
    -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg n "$_cn" '{"name":$n}')") || true
  _id=$(printf '%s' "$_resp" | jq -r '.channel._id // empty')
  if [ -z "$_id" ]; then
    _id=$(curl -sf "${RC_URL}/api/v1/channels.info?roomName=${_cn}" \
      -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" 2>/dev/null \
    | jq -r '.channel._id // empty') || true
  fi
  if [ "$_ro" = "true" ] && [ -n "$_id" ]; then
    curl -s -X POST "${RC_URL}/api/v1/channels.setReadOnly" \
      -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg id "$_id" '{"roomId":$id,"readOnly":true}')" >/dev/null || true
  fi
  printf '%s' "$_id"
}

add_user_to_channel() {
  curl -s -X POST "${RC_URL}/api/v1/channels.invite" \
    -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg rid "$2" --arg uid "$1" '{"roomId":$rid,"userId":$uid}')" \
    >/dev/null || true
}

get_or_create_team() {
  _tn="$1"
  _resp=$(curl -s -X POST "${RC_URL}/api/v1/teams.create" \
    -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg n "$_tn" '{"name":$n,"type":0}')") || true
  _id=$(printf '%s' "$_resp" | jq -r '.team._id // empty')
  if [ -z "$_id" ]; then
    _id=$(curl -sf "${RC_URL}/api/v1/teams.info?teamName=${_tn}" \
      -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" 2>/dev/null \
    | jq -r '.teamInfo._id // empty') || true
  fi
  printf '%s' "$_id"
}

add_user_to_team() {
  curl -s -X POST "${RC_URL}/api/v1/teams.addMembers" \
    -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg tid "$2" --arg uid "$1" \
      '{"teamId":$tid,"members":[{"userId":$uid,"roles":[]}]}')" >/dev/null || true
}

post_and_pin() {
  _rid="$1"; _msg="$2"
  _post=$(curl -sf -X POST "${RC_URL}/api/v1/chat.postMessage" \
    -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg rid "$_rid" --arg t "$_msg" '{"roomId":$rid,"text":$t}')") || true
  _mid=$(printf '%s' "$_post" | jq -r '.message._id // empty')
  if [ -n "$_mid" ]; then
    curl -sf -X POST "${RC_URL}/api/v1/chat.pinMessage" \
      -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg mid "$_mid" '{"messageId":$mid}')" >/dev/null || true
  fi
}

create_user() {
  _username="$1"; _email="$2"; _password="$3"; _name="$4"; _roles="$5"
  echo "[init] Creating user: ${_username} ..."
  _payload=$(jq -n --arg u "${_username}" --arg e "${_email}" \
    --arg p "${_password}" --arg n "${_name}" --argjson r "${_roles}" \
    '{"username":$u,"email":$e,"password":$p,"name":$n,"roles":$r,
      "joinDefaultChannels":true,"sendWelcomeEmail":false,"verified":true,
      "requirePasswordChange":false}')
  _resp=$(curl -sf -X POST "${RC_URL}/api/v1/users.create" \
    -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
    -H "Content-Type: application/json" -d "${_payload}" 2>&1) || true
  _success=$(printf '%s' "${_resp}" | jq -r '.success // false')
  _error=$(printf '%s' "${_resp}"   | jq -r '.error   // ""')
  if [ "${_success}" = "true" ]; then
    echo "[init]   created."
  elif printf '%s' "${_error}" | grep -qi "already in use\|already exists\|duplicate"; then
    echo "[init]   already exists -- skipping."
  else
    echo "[init]   WARNING: unexpected response: ${_resp}"
  fi
}

generate_token() {
  _username="$1"; _password="$2"
  echo "[token] Generating PAT for ${_username} ..."
  _user_auth=$(curl -sf -X POST "${RC_URL}/api/v1/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "${_username}" --arg p "${_password}" \
      '{"username":$u,"password":$p}')") || true
  _user_token=$(printf '%s' "${_user_auth}" | jq -r '.data.authToken // ""')
  _user_id=$(printf '%s' "${_user_auth}"    | jq -r '.data.userId    // ""')
  if [ -z "${_user_token}" ] || [ "${_user_token}" = "null" ]; then
    echo "[token]   WARNING: could not log in as ${_username} -- skipping."; return
  fi
  # Delete existing "api-token" PAT if present so reprovision always gets a fresh value.
  curl -sf -X POST "${RC_URL}/api/v1/users.removePersonalAccessToken" \
    -H "X-Auth-Token: ${_user_token}" -H "X-User-Id: ${_user_id}" \
    -H "Content-Type: application/json" -d '{"tokenName":"api-token"}' >/dev/null 2>&1 || true
  _token_resp=$(curl -sf -X POST "${RC_URL}/api/v1/users.generatePersonalAccessToken" \
    -H "X-Auth-Token: ${_user_token}" -H "X-User-Id: ${_user_id}" \
    -H "Content-Type: application/json" -d '{"tokenName":"api-token"}') || true
  _pat=$(printf '%s' "${_token_resp}" | jq -r '.token // empty')
  if [ -z "${_pat}" ]; then
    echo "[token]   WARNING: could not generate PAT."; return
  fi
  echo "[token]   done."
  printf '%s:%s\n' "${_username}" "${_pat}" >> "${TOKENS_FILE}"
}

# 1. Wait for Rocket.Chat health
echo "[init] Waiting for Rocket.Chat at ${RC_URL} ..."
attempts=0; max_attempts=60
until curl -sf "${RC_URL}/health" >/dev/null 2>&1; do
  attempts=$((attempts + 1))
  [ "${attempts}" -ge "${max_attempts}" ] && { echo "[init] ERROR: timeout."; exit 1; }
  echo "[init] Waiting ... (${attempts}/${max_attempts})"; sleep 3
done
echo "[init] Rocket.Chat is up."

# 2. Idempotency stamp
if [ -f "${STAMP_FILE}" ]; then echo "[init] Already provisioned. Exiting."; exit 0; fi
mkdir -p /tokens; : > "${TOKENS_FILE}"; : > "${_CH_MAP}"; : > "${_TEAM_MAP}"

# 3. Admin login
echo "[init] Logging in as ${RC_ADMIN_USER} ..."
auth_resp=$(curl -sf -X POST "${RC_URL}/api/v1/login" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "${RC_ADMIN_USER}" --arg p "${RC_ADMIN_PASS}" \
    '{"username":$u,"password":$p}')")
rc_admin_token=$(printf '%s' "${auth_resp}" | jq -r '.data.authToken')
rc_admin_id=$(printf '%s' "${auth_resp}"    | jq -r '.data.userId')
if [ -z "${rc_admin_token}" ] || [ "${rc_admin_token}" = "null" ]; then
  echo "[init] ERROR: auth failed."; exit 1
fi
echo "[init] Admin auth OK (userId=${rc_admin_id})."

# 4. Bootstrap custom OAuth providers (detected from OVERWRITE_SETTING_ env vars)
# addOAuthService seeds the settings doc so OVERWRITE_SETTING_ values take effect.
echo "[init] --- Bootstrapping custom OAuth providers ---"
_oauth_names=$(env | grep '^OVERWRITE_SETTING_Accounts_OAuth_Custom-[^-]*=' \
  | sed 's/^OVERWRITE_SETTING_Accounts_OAuth_Custom-\([^-=]*\)=.*/\1/')
if [ -z "$_oauth_names" ]; then
  echo "[init]   No custom OAuth providers configured -- skipping."
else
  printf '%s\n' "$_oauth_names" | while IFS= read -r _pname; do
    [ -z "$_pname" ] && continue
    _existing=$(curl -sf "${RC_URL}/api/v1/settings/Accounts_OAuth_Custom-${_pname}" \
      -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" 2>/dev/null \
      | jq -r '.setting._id // empty') || true
    if [ -z "$_existing" ]; then
      _inner=$(jq -n --arg n "$_pname" \
        '{"msg":"method","method":"addOAuthService","params":[$n],"id":"1"}')
      _payload=$(jq -n --arg m "$_inner" '{"message":$m}')
      curl -sf -X POST "${RC_URL}/api/v1/method.call/addOAuthService" \
        -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
        -H "Content-Type: application/json" -d "$_payload" >/dev/null || true
      echo "[init]   OAuth provider '${_pname}' created."
    else
      echo "[init]   OAuth provider '${_pname}' already exists -- skipping."
    fi
  done
fi

# 5. Create admin users
echo "[init] --- Creating admin users ---"
admin_count=$(yq '.admins | length' "${USERS_FILE}")
i=0; while [ "${i}" -lt "${admin_count}" ]; do
  create_user "$(yq ".admins[${i}].username" "${USERS_FILE}")" \
    "$(yq ".admins[${i}].email"    "${USERS_FILE}")" \
    "$(yq ".admins[${i}].password" "${USERS_FILE}")" \
    "$(yq ".admins[${i}].name"     "${USERS_FILE}")" '["admin"]'
  i=$((i + 1)); done

# 5. Create regular users
echo "[init] --- Creating regular users ---"
user_count=$(yq '.users | length' "${USERS_FILE}")
i=0; while [ "${i}" -lt "${user_count}" ]; do
  create_user "$(yq ".users[${i}].username" "${USERS_FILE}")" \
    "$(yq ".users[${i}].email"    "${USERS_FILE}")" \
    "$(yq ".users[${i}].password" "${USERS_FILE}")" \
    "$(yq ".users[${i}].name"     "${USERS_FILE}")" '["user"]'
  i=$((i + 1)); done

# 6. Generate personal access tokens
echo "[init] --- Generating personal access tokens ---"
i=0; while [ "${i}" -lt "${admin_count}" ]; do
  generate_token "$(yq ".admins[${i}].username" "${USERS_FILE}")" \
    "$(yq ".admins[${i}].password" "${USERS_FILE}")"; i=$((i+1)); done
i=0; while [ "${i}" -lt "${user_count}" ]; do
  generate_token "$(yq ".users[${i}].username" "${USERS_FILE}")" \
    "$(yq ".users[${i}].password" "${USERS_FILE}")"; i=$((i+1)); done

# 7. Predefined channels
echo "[init] --- Creating predefined channels ---"
ch_count=$(yq '.channels | length' "${USERS_FILE}" 2>/dev/null || echo 0)
i=0; while [ "${i}" -lt "${ch_count}" ]; do
  ch_name=$(yq ".channels[${i}].name"             "${USERS_FILE}")
  ch_ro=$(yq   ".channels[${i}].readonly // false" "${USERS_FILE}")
  ch_id=$(get_or_create_channel "$ch_name" "$ch_ro")
  if [ -n "$ch_id" ]; then
    echo "[init]   #${ch_name} (id=${ch_id}, readonly=${ch_ro})"
    printf '%s:%s\n' "$ch_name" "$ch_id" >> "${_CH_MAP}"
  else echo "[init]   WARNING: could not get ID for #${ch_name}"; fi
  i=$((i + 1)); done

# 8. RC Teams
echo "[init] --- Creating RC Teams ---"
team_count=$(yq '.teams | length' "${USERS_FILE}" 2>/dev/null || echo 0)
i=0; while [ "${i}" -lt "${team_count}" ]; do
  t_name=$(yq ".teams[${i}].name" "${USERS_FILE}")
  t_id=$(get_or_create_team "$t_name")
  if [ -n "$t_id" ]; then
    echo "[init]   team: ${t_name} (id=${t_id})"
    printf '%s:%s\n' "$t_name" "$t_id" >> "${_TEAM_MAP}"
  else echo "[init]   WARNING: could not create team '${t_name}'"; fi
  i=$((i + 1)); done

# 9. Auto-join rules + team membership
echo "[init] --- Applying auto_join rules ---"
aj_count=$(yq '.auto_join | length' "${USERS_FILE}" 2>/dev/null || echo 0)
aj=0; while [ "${aj}" -lt "${aj_count}" ]; do
  aj_group=$(yq ".auto_join[${aj}].group" "${USERS_FILE}")
  aj_ch_count=$(yq ".auto_join[${aj}].channels | length" "${USERS_FILE}")
  case "${aj_group}" in
    users)  src_array="users";  src_count="${user_count}"  ;;
    admins) src_array="admins"; src_count="${admin_count}" ;;
    *) echo "[init]   unknown group '${aj_group}' -- skipping"; aj=$((aj+1)); continue ;;
  esac
  echo "[init]   group=${aj_group} -> ${aj_ch_count} channel(s)"
  mi=0; while [ "${mi}" -lt "${src_count}" ]; do
    m_user=$(yq ".${src_array}[${mi}].username" "${USERS_FILE}")
    m_uid=$(get_user_id "$m_user") || true
    if [ -n "$m_uid" ]; then
      ci=0; while [ "${ci}" -lt "${aj_ch_count}" ]; do
        aj_ch=$(yq ".auto_join[${aj}].channels[${ci}]" "${USERS_FILE}")
        aj_ch_id=$(channel_id_for "$aj_ch")
        [ -n "$aj_ch_id" ] && add_user_to_channel "$m_uid" "$aj_ch_id"
        ci=$((ci + 1)); done; fi
    mi=$((mi + 1)); done
  aj=$((aj + 1)); done

instr_team_id=$(grep "^instructors:" "${_TEAM_MAP}" 2>/dev/null | head -1 | cut -d: -f2 || true)
trainee_team_id=$(grep "^trainees:" "${_TEAM_MAP}" 2>/dev/null | head -1 | cut -d: -f2 || true)
if [ -n "${instr_team_id}" ]; then
  echo "[init]   Adding admins to 'instructors' team ..."
  i=0; while [ "${i}" -lt "${admin_count}" ]; do
    uid=$(get_user_id "$(yq ".admins[${i}].username" "${USERS_FILE}")") || true
    [ -n "$uid" ] && add_user_to_team "$uid" "$instr_team_id"; i=$((i+1)); done; fi
if [ -n "${trainee_team_id}" ]; then
  echo "[init]   Adding users to 'trainees' team ..."
  i=0; while [ "${i}" -lt "${user_count}" ]; do
    uid=$(get_user_id "$(yq ".users[${i}].username" "${USERS_FILE}")") || true
    [ -n "$uid" ] && add_user_to_team "$uid" "$trainee_team_id"; i=$((i+1)); done; fi

# 10. Player-team channels from RC_TEAMS env
echo "[init] --- Creating player-team channels ---"
if [ -n "${RC_TEAMS}" ]; then
  printf '%s\n' "${RC_TEAMS}" | tr ',' '\n' | while IFS= read -r pt_name; do
    [ -z "$pt_name" ] && continue
    pt_id=$(get_or_create_channel "$pt_name" "false")
    echo "[init]   #${pt_name} (id=${pt_id})"
    printf '%s:%s\n' "$pt_name" "$pt_id" >> "${_CH_MAP}"
  done
else echo "[init]   RC_TEAMS not set -- skipping."; fi

# 11. Auto-join users to their player_team channel
echo "[init] --- Auto-joining users to player_team channels ---"
i=0; while [ "${i}" -lt "${user_count}" ]; do
  u_name=$(yq ".users[${i}].username"              "${USERS_FILE}")
  u_pt=$(yq   ".users[${i}].player_team // \"\""    "${USERS_FILE}")
  if [ -n "$u_pt" ] && [ "$u_pt" != "null" ]; then
    u_uid=$(get_user_id "$u_name") || true
    pt_ch_id=$(channel_id_for "$u_pt")
    if [ -n "$u_uid" ] && [ -n "$pt_ch_id" ]; then
      add_user_to_channel "$u_uid" "$pt_ch_id"
      echo "[init]   ${u_name} -> #${u_pt}"
    else echo "[init]   WARNING: no channel for player_team '${u_pt}' (user ${u_name})"; fi
  fi; i=$((i + 1)); done

# 12. Bot account
echo "[init] --- Creating bot account ---"
bot_username=$(yq '.bot.username // "rc-bot"'          "${USERS_FILE}" 2>/dev/null || echo "rc-bot")
bot_name=$(yq     '.bot.name // "Range42 Bot"'         "${USERS_FILE}" 2>/dev/null || echo "Range42 Bot")
bot_email=$(yq    '.bot.email // "bot@range42.local"'  "${USERS_FILE}" 2>/dev/null || echo "bot@range42.local")
bot_pass=$(yq     '.bot.password // "Bot1234!"'        "${USERS_FILE}" 2>/dev/null || echo "Bot1234!")
_bot_resp=$(curl -s -X POST "${RC_URL}/api/v1/users.create" \
  -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "$bot_username" --arg e "$bot_email" \
    --arg p "$bot_pass" --arg n "$bot_name" \
    '{"username":$u,"email":$e,"password":$p,"name":$n,"roles":["bot"],
      "joinDefaultChannels":false,"sendWelcomeEmail":false,"verified":true,
      "requirePasswordChange":false}')") || true
bot_id=$(printf '%s' "$_bot_resp" | jq -r '.user._id // empty')
[ -z "$bot_id" ] && bot_id=$(get_user_id "$bot_username") || true
if [ -n "$bot_id" ]; then
  echo "[init]   Bot: ${bot_username} (id=${bot_id})"
  _bot_auth=$(curl -sf -X POST "${RC_URL}/api/v1/login" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$bot_username" --arg p "$bot_pass" \
      '{"username":$u,"password":$p}')") || true
  _bot_sess=$(printf '%s' "$_bot_auth" | jq -r '.data.authToken // ""')
  _bot_uid=$(printf '%s'  "$_bot_auth" | jq -r '.data.userId    // ""')
  if [ -n "$_bot_sess" ] && [ "$_bot_sess" != "null" ]; then
    curl -s -X POST "${RC_URL}/api/v1/permissions.update" \
      -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
      -H "Content-Type: application/json" \
      -d '{"permissions":[{"_id":"create-personal-access-tokens","roles":["admin","user","bot"]}]}' \
      >/dev/null || true
    # Delete existing "bot-api-token" PAT if present so reprovision always gets a fresh value.
    curl -sf -X POST "${RC_URL}/api/v1/users.removePersonalAccessToken" \
      -H "X-Auth-Token: ${_bot_sess}" -H "X-User-Id: ${_bot_uid}" \
      -H "Content-Type: application/json" \
      -d '{"tokenName":"bot-api-token"}' >/dev/null 2>&1 || true
    _bot_pat=$(curl -sf -X POST "${RC_URL}/api/v1/users.generatePersonalAccessToken" \
      -H "X-Auth-Token: ${_bot_sess}" -H "X-User-Id: ${_bot_uid}" \
      -H "Content-Type: application/json" \
      -d '{"tokenName":"bot-api-token"}') || true
    bot_token=$(printf '%s' "$_bot_pat" | jq -r '.token // ""')
    if [ -n "$bot_token" ] && [ "$bot_token" != "null" ]; then
      printf 'bot:%s\n' "$bot_token" >> "${TOKENS_FILE}"
      echo "[init]   Bot PAT generated."
    else echo "[init]   WARNING: could not generate bot PAT."; fi; fi
  while IFS=: read -r _chn _chid; do
    [ -n "$_chid" ] && add_user_to_channel "$bot_id" "$_chid"
  done < "${_CH_MAP}" 2>/dev/null || true
else echo "[init]   WARNING: could not create or locate bot account."; fi

# 13. Incoming webhooks
echo "[init] --- Creating incoming webhooks ---"
curl -s -X POST "${RC_URL}/api/v1/permissions.update" \
  -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
  -H "Content-Type: application/json" \
  -d '{"permissions":[{"_id":"message-impersonate","roles":["admin","bot"]}]}' \
  >/dev/null || true
wh_count=$(yq '.incoming_webhooks | length' "${USERS_FILE}" 2>/dev/null || echo 0)
wi=0; while [ "${wi}" -lt "${wh_count}" ]; do
  wh_name=$(yq ".incoming_webhooks[${wi}].name"    "${USERS_FILE}")
  wh_chan=$(yq  ".incoming_webhooks[${wi}].channel" "${USERS_FILE}")
  # Check if a webhook with this name already exists (idempotency on reprovision).
  _existing_wh=$(curl -sf "${RC_URL}/api/v1/integrations.list" \
    -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" 2>/dev/null \
    | jq -r --arg n "$wh_name" \
      '.integrations[] | select(.type=="webhook-incoming" and .name==$n) | "\(._id):\(.token)"' \
    | head -1) || true
  if [ -n "$_existing_wh" ]; then
    _wh_id=$(printf '%s' "$_existing_wh"  | cut -d: -f1)
    _wh_tok=$(printf '%s' "$_existing_wh" | cut -d: -f2-)
    echo "[init]   '${wh_name}' already exists -- reusing."
  else
    _wh_resp=$(curl -sf -X POST "${RC_URL}/api/v1/integrations.create" \
      -H "X-Auth-Token: ${rc_admin_token}" -H "X-User-Id: ${rc_admin_id}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg n "$wh_name" --arg ch "$wh_chan" --arg u "$bot_username" \
        '{"type":"webhook-incoming","name":$n,"enabled":true,"channel":$ch,
          "username":$u,"scriptEnabled":false,
          "overrideDestinationChannelEnabled":true}')") || true
    _wh_id=$(printf '%s'  "$_wh_resp" | jq -r '.integration._id   // empty')
    _wh_tok=$(printf '%s' "$_wh_resp" | jq -r '.integration.token // empty')
  fi
  if [ -n "$_wh_id" ] && [ -n "$_wh_tok" ]; then
    incoming_webhook_url="${RC_BASE_URL}/hooks/${_wh_id}/${_wh_tok}"
    printf 'webhook_incoming:%s\n' "${incoming_webhook_url}" >> "${TOKENS_FILE}"
    echo "[init]   '${wh_name}' -> ${incoming_webhook_url}"
  else echo "[init]   WARNING: could not create webhook '${wh_name}'."; fi
  wi=$((wi + 1)); done

# 14. Register RC incoming webhook on Gitea repos
echo "[init] --- Registering RC webhook on Gitea repos ---"
if [ -z "${GITEA_URL}" ] || [ -z "${GITEA_ADMIN_USER}" ] || [ -z "${GITEA_ADMIN_PASS}" ]; then
  echo "[init]   GITEA_URL/GITEA_ADMIN_USER/GITEA_ADMIN_PASS not set -- skipping."
elif [ -z "${incoming_webhook_url}" ]; then
  echo "[init]   No incoming webhook URL available -- skipping."
else
  _GITEA_EVENTS='["push","issues","issue_comment","issue_label","issue_assign","issue_milestone","pull_request","pull_request_assign","pull_request_label","pull_request_comment","pull_request_review","pull_request_review_request","pull_request_sync","pull_request_milestone"]'
  # Wait briefly for Gitea to be reachable (parallel startup on fresh deploy).
  _gi=0
  until curl -skf -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      "${GITEA_URL}/api/v1/user" >/dev/null 2>&1; do
    _gi=$((_gi + 1))
    [ "${_gi}" -ge 12 ] && { echo "[init]   WARNING: Gitea not reachable after 60s -- skipping."; break; }
    echo "[init]   Waiting for Gitea ... (${_gi}/12)"; sleep 5
  done
  if curl -skf -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      "${GITEA_URL}/api/v1/user" >/dev/null 2>&1; then
    _repos=$(curl -sk -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      "${GITEA_URL}/api/v1/repos/search?limit=50" \
      | jq -r '.data[].full_name') || true
    printf '%s\n' "$_repos" | while IFS= read -r _repo; do
      [ -z "$_repo" ] && continue
      _existing_gh=$(curl -sk -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
        "${GITEA_URL}/api/v1/repos/${_repo}/hooks" \
        | jq -r --arg u "$incoming_webhook_url" \
          '.[] | select(.config.url==$u) | .id' | head -1) || true
      if [ -n "$_existing_gh" ]; then
        echo "[init]   ${_repo}: already has RC webhook (id=${_existing_gh}) -- skipping."
      else
        _gh_resp=$(curl -sk -X POST \
          -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
          "${GITEA_URL}/api/v1/repos/${_repo}/hooks" \
          -H 'Content-Type: application/json' \
          -d "$(jq -n --arg url "$incoming_webhook_url" \
            --argjson ev "$_GITEA_EVENTS" \
            '{"type":"slack","active":true,"events":$ev,
              "config":{"url":$url,"content_type":"json","channel":"#general"}}')") || true
        _gh_id=$(printf '%s' "$_gh_resp" | jq -r '.id // empty') || true
        if [ -n "$_gh_id" ]; then
          echo "[init]   ${_repo}: RC webhook registered (id=${_gh_id})."
        else
          echo "[init]   ${_repo}: WARNING could not register RC webhook."
        fi
      fi
    done
  fi
fi

# 15. Pin welcome messages
echo "[init] --- Pinning welcome messages ---"
i=0; while [ "${i}" -lt "${ch_count}" ]; do
  pin_msg=$(yq ".channels[${i}].pinned_message // \"\"" "${USERS_FILE}" 2>/dev/null || true)
  if [ -n "$pin_msg" ] && [ "$pin_msg" != "null" ]; then
    ch_name=$(yq ".channels[${i}].name" "${USERS_FILE}")
    ch_id=$(channel_id_for "$ch_name")
    if [ -n "$ch_id" ]; then post_and_pin "$ch_id" "$pin_msg"
      echo "[init]   Pinned in #${ch_name}"; fi; fi
  i=$((i + 1)); done

# 15. Custom status guide pinned in #general
echo "[init] --- Custom status guide ---"
cs_count=$(yq '.custom_statuses | length' "${USERS_FILE}" 2>/dev/null || echo 0)
if [ "${cs_count}" -gt 0 ]; then
  gen_id=$(channel_id_for "general")
  if [ -n "$gen_id" ]; then
    guide="**Training custom statuses** -- set via your avatar > Edit Status\n\n"
    cs=0; while [ "${cs}" -lt "${cs_count}" ]; do
      cs_text=$(yq ".custom_statuses[${cs}].text"  "${USERS_FILE}")
      cs_emoji=$(yq ".custom_statuses[${cs}].emoji" "${USERS_FILE}")
      guide="${guide}:${cs_emoji}: **${cs_text}**\n"; cs=$((cs+1)); done
    post_and_pin "$gen_id" "$(printf '%b' "$guide")"
    echo "[init]   Status guide pinned in #general."; fi; fi

# 16. Emit credentials JSON
echo "[init] --- Writing rocketchat-credentials.json ---"
_user_tokens_json='[]'
while IFS=: read -r _uname _utok; do
  case "$_uname" in bot|webhook_incoming) continue ;; esac
  _user_tokens_json=$(printf '%s' "$_user_tokens_json" | \
    jq --arg u "$_uname" --arg t "$_utok" '. + [{"username":$u,"token":$t}]')
done < "${TOKENS_FILE}" 2>/dev/null || true
_channels_json='[]'
while IFS=: read -r _chn _chid; do
  [ -n "$_chid" ] || continue
  _channels_json=$(printf '%s' "$_channels_json" | \
    jq --arg n "$_chn" --arg id "$_chid" '. + [{"name":$n,"id":$id}]')
done < "${_CH_MAP}" 2>/dev/null || true
_player_teams_json='[]'
[ -n "${RC_TEAMS}" ] && \
  _player_teams_json=$(printf '%s' "${RC_TEAMS}" | jq -Rc '[split(",")[]]')
jq -n \
  --arg  service        "rocketchat" \
  --arg  url            "${RC_BASE_URL}" \
  --arg  admin_user     "${RC_ADMIN_USER}" \
  --arg  admin_pass     "${RC_ADMIN_PASS}" \
  --arg  bot_user       "${bot_username}" \
  --arg  bot_tok        "${bot_token}" \
  --arg  wh_url         "${incoming_webhook_url}" \
  --argjson channels     "${_channels_json}" \
  --argjson player_teams "${_player_teams_json}" \
  --argjson user_tokens  "${_user_tokens_json}" \
  '{
    "service": $service, "url": $url,
    "admin": {"username": $admin_user, "password": $admin_pass},
    "service_specific": {
      "channels": $channels, "player_teams": $player_teams,
      "bot_account": {"username": $bot_user, "token": $bot_tok},
      "incoming_webhook_url": $wh_url,
      "auto_joined_channels": "each user is added to the channel matching their player_team value"
    },
    "user_tokens": $user_tokens
  }' > "${CREDS_FILE}" || echo "[init] WARNING: could not write ${CREDS_FILE}."
echo "[init] Credentials written to ${CREDS_FILE}."

# 17. Summary + stamp
echo ""; echo "[init] ─────────────────────────────────────────────────────"
echo "[init] Provisioning complete."
echo "[init] Tokens      : ${TOKENS_FILE}  (make tokens)"
echo "[init] Credentials : ${CREDS_FILE}   (make creds)"
echo "[init] ─────────────────────────────────────────────────────"
touch "${STAMP_FILE}"; echo "[init] Done."
