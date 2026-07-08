#!/usr/bin/env bash
#
# range42-catalog - credentials.vaultwarden - sync engine
#
# Drives the official Bitwarden CLI (`bw`) against a self-hosted Vaultwarden
# server to sync values between an Ansible vault and Vaultwarden items.
#
# Runs on the Ansible control node (the role calls it with delegate_to:
# localhost). One atomic invocation: log in, unlock, process the whole plan,
# then always log out - so no bw session is left behind.
#
# Secrets are passed ONLY via the environment and stdin - never on argv (which
# is world-visible in `ps`). This script itself never writes secrets to disk.
# NOTE: Ansible invokes it with delegate_to: localhost via the command module,
# whose AnsiballZ wrapper may briefly stage the delegated env/stdin in a temp
# module file under ~/.ansible/tmp/. no_log hides it from output but not from
# disk, so do NOT run this role with ANSIBLE_KEEP_REMOTE_FILES=1 or -vvvv.
#
#   Environment (required):
#     VW_URL            Vaultwarden base URL (e.g. http://10.0.0.5:8080)
#     BW_CLIENTID       API-key client_id     (personal API key)
#     BW_CLIENTSECRET   API-key client_secret
#     BW_PASSWORD       account master password (to unlock the vault)
#   Environment (optional):
#     VW_ORG_ID         organization id - scopes items to an org
#     VW_COLLECTION_ID  collection id   - REQUIRED by Vaultwarden for org items
#
#   Plan (stdin, JSON):
#     { "entries": [
#         {"vault_var":"x","item":"name","field":"f","direction":"set","value":"secret"},
#         {"vault_var":"y","item":"name","field":"f","direction":"get"}
#     ] }
#
#   Output (stdout, JSON): only the `get` results, keyed by vault_var:
#     {"y":"pulled-value"}
#
# Fails loudly (non-zero exit, message on stderr, NO secret values in the
# message) on: missing tooling, unreachable server, auth failure, ambiguous
# item name, or a missing item/field on a `get`. This is secret distribution -
# there are deliberately no silent fallbacks.
#

set -euo pipefail

fail() { printf '[credentials.vaultwarden] FATAL: %s\n' "$*" >&2; exit 1; }

command -v bw >/dev/null 2>&1 || fail "Bitwarden CLI 'bw' not found on the control node. Install it (npm i -g @bitwarden/cli, snap, or the release binary) - it is how Vaultwarden is reached."
command -v jq >/dev/null 2>&1 || fail "'jq' not found on the control node."

: "${VW_URL:?VW_URL not set}"
: "${BW_CLIENTID:?BW_CLIENTID not set}"
: "${BW_CLIENTSECRET:?BW_CLIENTSECRET not set}"
: "${BW_PASSWORD:?BW_PASSWORD not set}"

PLAN="$(cat)"
echo "$PLAN" | jq -e . >/dev/null 2>&1 || fail "stdin plan is not valid JSON"

# Isolate CLI state in a private appdata dir so we never read or clobber a
# developer's real `bw` login/config on the control node. A recognizable prefix
# lets us identify and purge leftovers from a prior hard-killed run.
_VW_APPDATA_PREFIX="vw_sync_bw_appdata"
_VW_TMPDIR="${TMPDIR:-/tmp}"

# SIGKILL / OOM / a control-node crash cannot be trapped, so an earlier run may
# have left an appdata dir (holding a live bw session) behind. Self-contained
# housekeeping: purge our own stale dirs (older than 1 day) up front - no
# external cron/timer required.
find "$_VW_TMPDIR" -maxdepth 1 -type d -name "${_VW_APPDATA_PREFIX}.*" -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

BITWARDENCLI_APPDATA_DIR="$(mktemp -d "${_VW_TMPDIR}/${_VW_APPDATA_PREFIX}.XXXXXX")"
export BITWARDENCLI_APPDATA_DIR
cleanup() {
  bw logout >/dev/null 2>&1 || true
  rm -rf "$BITWARDENCLI_APPDATA_DIR"
}
trap cleanup EXIT INT TERM

bw config server "$VW_URL" >/dev/null 2>&1 || fail "could not point bw at server $VW_URL"

# Clean slate, then non-interactive API-key login (reads BW_CLIENTID/SECRET).
bw logout >/dev/null 2>&1 || true
bw login --apikey >/dev/null 2>&1 || fail "bw login failed - check client_id/secret and that $VW_URL is reachable"

BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)" || fail "bw unlock failed - check the master password"
export BW_SESSION
bw sync >/dev/null 2>&1 || fail "bw sync failed - is Vaultwarden reachable at $VW_URL ?"

# Org scoping args, reused for reads and writes.
ORG_ARG=()
[ -n "${VW_ORG_ID:-}" ] && ORG_ARG=(--organizationid "$VW_ORG_ID")

# Return the single exact-name item as JSON, or "" if none. Fails on ambiguity.
find_item() {
  local name="$1" matches count
  matches="$(bw list items "${ORG_ARG[@]}" --search "$name" 2>/dev/null \
             | jq -c --arg n "$name" '[.[] | select(.name == $n)]')" \
    || fail "could not list items while looking up '$name'"
  count="$(printf '%s' "$matches" | jq 'length')"
  if [ "$count" -gt 1 ]; then
    fail "item name '$name' is ambiguous ($count exact matches) - item names must be unique"
  elif [ "$count" -eq 1 ]; then
    printf '%s' "$matches" | jq -c '.[0]'
  else
    printf ''
  fi
}

results='{}'

n="$(printf '%s' "$PLAN" | jq '.entries | length')"
i=0
while [ "$i" -lt "$n" ]; do
  entry="$(printf '%s' "$PLAN" | jq -c ".entries[$i]")"
  var="$(printf '%s' "$entry" | jq -r '.vault_var')"
  item="$(printf '%s' "$entry" | jq -r '.item')"
  field="$(printf '%s' "$entry" | jq -r '.field')"
  direction="$(printf '%s' "$entry" | jq -r '.direction')"

  case "$direction" in
    get)
      found="$(find_item "$item")"
      [ -n "$found" ] || fail "get: item '$item' not found in Vaultwarden"
      # Collect matching custom field(s). Guard against duplicate field names the
      # same way find_item guards duplicate item names - no silent pick-one.
      fmatches="$(printf '%s' "$found" | jq -c --arg f "$field" '[.fields[]? | select(.name == $f)]')"
      fcount="$(printf '%s' "$fmatches" | jq 'length')"
      [ "$fcount" -le 1 ] || fail "get: field '$field' is ambiguous ($fcount matches) on item '$item' - field names must be unique"
      [ "$fcount" -eq 1 ] || fail "get: field '$field' not found on item '$item'"
      # Distinguish a genuine JSON null (absent value) from a stored value that
      # is literally the text "null" or an empty string - each fails clearly.
      [ "$(printf '%s' "$fmatches" | jq -r '.[0].value == null')" = "false" ] \
        || fail "get: field '$field' on item '$item' has a null value"
      value="$(printf '%s' "$fmatches" | jq -r '.[0].value')"
      [ -n "$value" ] || fail "get: field '$field' on item '$item' is empty - refusing to return a blank secret"
      # Pass the pulled secret via env (env.VW_SECRET_VALUE), never argv.
      results="$(printf '%s' "$results" | VW_SECRET_VALUE="$value" jq --arg k "$var" '. + {($k): env.VW_SECRET_VALUE}')"
      ;;
    set)
      value="$(printf '%s' "$entry" | jq -r '.value')"
      found="$(find_item "$item")"
      if [ -n "$found" ]; then
        # Update: upsert the custom hidden field (type 1) on the existing item.
        id="$(printf '%s' "$found" | jq -r '.id')"
        # Secret value goes via env (env.VW_SECRET_VALUE), never argv.
        updated="$(printf '%s' "$found" | VW_SECRET_VALUE="$value" jq --arg f "$field" '
          .fields = ((.fields // []) | map(select(.name != $f)))
                    + [{"name": $f, "value": env.VW_SECRET_VALUE, "type": 1}]')"
        printf '%s' "$updated" | bw encode | bw edit item "$id" >/dev/null \
          || fail "set: failed to update field '$field' on item '$item'"
      else
        # Create: a login-type item carrying the one custom hidden field.
        tmpl="$(bw get template item)" || fail "set: could not read item template"
        # Secret value goes via env (env.VW_SECRET_VALUE), never argv.
        newitem="$(printf '%s' "$tmpl" | VW_SECRET_VALUE="$value" jq \
          --arg name "$item" --arg f "$field" \
          --arg org "${VW_ORG_ID:-}" --arg col "${VW_COLLECTION_ID:-}" '
            .type = 1
            | .name = $name
            | .notes = null
            | .login = {"username": null, "password": null, "totp": null}
            | .fields = [{"name": $f, "value": env.VW_SECRET_VALUE, "type": 1}]
            | (if $org != "" then .organizationId = $org else . end)
            | (if $col != "" then .collectionIds = [$col] else . end)')"
        printf '%s' "$newitem" | bw encode | bw create item >/dev/null \
          || fail "set: failed to create item '$item' (org items require a collection id)"
      fi
      ;;
    *)
      fail "unknown direction '$direction' for '$var' (expected get|set)"
      ;;
  esac
  i=$((i + 1))
done

printf '%s\n' "$results"
