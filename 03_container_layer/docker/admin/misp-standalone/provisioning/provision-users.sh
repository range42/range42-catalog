#!/usr/bin/env bash
# Provisioner container entrypoint — runs ONCE after MISP is healthy.
#
# Reads the admin auth-key that entrypoint.sh wrote to /keys/admin-authkey,
# then uses the MISP REST API to:
#   1. Rename/update the default admin account
#   2. Create an optional second admin
#   3. Create the reader user  (role_id=6 — Read Only)
#   4. Create the writer user  (role_id=4 — Publisher)
#   5. Create per-team users   (lead org-admin + N regular users per team)
#   6. Emit all credentials to /keys/api-keys.txt
#
# Role IDs (MISP defaults):
#   1 = Site Admin    3 = User          5 = Sync User
#   2 = Org Admin     4 = Publisher     6 = Read Only
set -euo pipefail

MISP_URL="https://misp"
KEYS_FILE="/keys/api-keys.txt"
ADMIN_KEY_FILE="/keys/admin-authkey"
ORG_IDS_FILE="/keys/org-ids.env"

log()  { echo "[provisioner] $*" >&2; }
fail() { echo "[provisioner] ERROR: $*" >&2; exit 1; }

# ── Idempotency guard ─────────────────────────────────────────────────────────

if [ -s "${KEYS_FILE}" ]; then
    log "Keys file already exists — provisioning already done. Exiting."
    exit 0
fi

# ── Wait for admin auth-key ───────────────────────────────────────────────────

log "Waiting for admin auth-key …"
ADMIN_KEY=""
for i in $(seq 1 60); do
    ADMIN_KEY=$(tr -d '[:space:]' < "${ADMIN_KEY_FILE}" 2>/dev/null || true)
    [ -n "${ADMIN_KEY}" ] && break
    sleep 5
done
[ -n "${ADMIN_KEY}" ] || fail "admin-authkey did not appear within 300 s"
log "Admin auth-key loaded."

# ── REST helpers ──────────────────────────────────────────────────────────────

misp_post() {
    local path="$1" body="$2"
    curl -sk \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X POST \
        -d "${body}" \
        "${MISP_URL}${path}"
}

misp_put() {
    local path="$1" body="$2"
    curl -sk \
        -H "Authorization: ${ADMIN_KEY}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -X PUT \
        -d "${body}" \
        "${MISP_URL}${path}"
}

extract_key() {
    grep -oP '"authkey"\s*:\s*"\K[^"]+' || true
}

# ── Password generator ────────────────────────────────────────────────────────
# Produces a 20-char password satisfying MISP's 12-char minimum and typical
# complexity requirements (upper, lower, digit, special via the R42! prefix).

gen_password() {
    printf 'R42!%s' "$(openssl rand -base64 16 | tr -d '/+=')" | head -c 20
}

# ── User creation helper ──────────────────────────────────────────────────────
# Prints the authkey on stdout; all logs go to stderr.

create_user() {
    local email="$1" password="$2" role_id="$3" org_id="$4"
    misp_post "/admin/users/add" "$(cat <<JSON
{
  "email":            "${email}",
  "password":         "${password}",
  "confirm_password": "${password}",
  "role_id":          ${role_id},
  "org_id":           ${org_id},
  "change_pw":        0,
  "termsaccepted":    1
}
JSON
)" | extract_key
}

# ── 1. Update default admin account ──────────────────────────────────────────

log "Updating admin account (admin@admin.test → ${MISP_ADMIN_EMAIL:-admin@misp.local}) …"
misp_put "/admin/users/edit/1" "$(cat <<JSON
{
  "email":            "${MISP_ADMIN_EMAIL:-admin@misp.local}",
  "password":         "${MISP_ADMIN_PASSWORD:-Admin1234!}",
  "confirm_password": "${MISP_ADMIN_PASSWORD:-Admin1234!}",
  "change_pw":        0,
  "role_id":          1,
  "org_id":           1,
  "termsaccepted":    1
}
JSON
)" > /dev/null
log "Admin account updated."

# ── 2. Optional second admin ──────────────────────────────────────────────────

ADMIN2_KEY=""
if [ -n "${MISP_ADMIN2_EMAIL:-}" ] && [ -n "${MISP_ADMIN2_PASSWORD:-}" ]; then
    log "Creating second admin: ${MISP_ADMIN2_EMAIL} …"
    ADMIN2_KEY=$(misp_post "/admin/users/add" "$(cat <<JSON
{
  "email":            "${MISP_ADMIN2_EMAIL}",
  "password":         "${MISP_ADMIN2_PASSWORD}",
  "confirm_password": "${MISP_ADMIN2_PASSWORD}",
  "role_id":          1,
  "org_id":           1,
  "change_pw":        0,
  "termsaccepted":    1
}
JSON
)" | extract_key)
    log "Second admin created."
fi

# ── 3. Reader user (role_id=6 — Read Only) ───────────────────────────────────

log "Creating reader: ${MISP_READER_EMAIL:-reader@misp.local} …"
READER_KEY=$(create_user \
    "${MISP_READER_EMAIL:-reader@misp.local}" \
    "${MISP_READER_PASSWORD:-Reader1234!XYZ}" \
    6 1)
log "Reader created."

# ── 4. Writer user (role_id=4 — Publisher) ───────────────────────────────────

log "Creating writer: ${MISP_WRITER_EMAIL:-writer@misp.local} …"
WRITER_KEY=$(create_user \
    "${MISP_WRITER_EMAIL:-writer@misp.local}" \
    "${MISP_WRITER_PASSWORD:-Writer1234!XYZ}" \
    4 1)
log "Writer created."

# ── 5. Team users ─────────────────────────────────────────────────────────────
# Reads org IDs from /keys/org-ids.env (written by provision-orgs.sh).
# Creates one org-admin lead + MISP_USERS_PER_TEAM regular users per team,
# plus MISP_INSTRUCTOR_COUNT org-admin accounts in the instructor org.

USERS_PER_TEAM="${MISP_USERS_PER_TEAM:-2}"
USER_DOMAIN="${MISP_USER_DOMAIN:-range42.local}"
INSTRUCTOR_COUNT="${MISP_INSTRUCTOR_COUNT:-1}"

TEAM_LINES=""

if [ ! -f "${ORG_IDS_FILE}" ]; then
    log "WARNING: ${ORG_IDS_FILE} not found — skipping team provisioning."
else
    # shellcheck source=/dev/null
    . "${ORG_IDS_FILE}"

    INSTRUCTOR_ORG="${MISP_INSTRUCTOR_ORG:-instructors}"
    INSTR_ORG_VAR="MISP_ORG_ID_$(echo "${INSTRUCTOR_ORG}" | tr '[:lower:]-' '[:upper:]_')"
    INSTR_ORG_ID="${!INSTR_ORG_VAR:-}"

    if [ -n "${INSTR_ORG_ID}" ]; then
        TEAM_LINES+=$'\n# ── Instructors ──────────────────────────────────────────────────────\n'
        for i in $(seq 1 "${INSTRUCTOR_COUNT}"); do
            suffix=$( [ "${INSTRUCTOR_COUNT}" -eq 1 ] && echo "" || echo "${i}" )
            email="instructor${suffix}@${USER_DOMAIN}"
            pass=$(gen_password)
            key=$(create_user "${email}" "${pass}" 2 "${INSTR_ORG_ID}")
            log "Created instructor: ${email}"
            TEAM_LINES+="# instructor${suffix} — org: ${INSTRUCTOR_ORG}, role: Org Admin"$'\n'
            TEAM_LINES+="MISP_INSTRUCTOR${i}_EMAIL=${email}"$'\n'
            TEAM_LINES+="MISP_INSTRUCTOR${i}_PASSWORD=${pass}"$'\n'
            TEAM_LINES+="MISP_INSTRUCTOR${i}_KEY=${key}"$'\n'
        done
    else
        log "WARNING: no org ID for '${INSTRUCTOR_ORG}' — skipping instructor accounts."
    fi

    IFS=',' read -ra TEAM_LIST <<< "${MISP_TEAMS:-team-blue,team-red}"
    for raw_team in "${TEAM_LIST[@]}"; do
        team=$(echo "${raw_team}" | tr -d '[:space:]')
        [ -z "${team}" ] && continue

        TEAM_ORG_VAR="MISP_ORG_ID_$(echo "${team}" | tr '[:lower:]-' '[:upper:]_')"
        TEAM_ORG_ID="${!TEAM_ORG_VAR:-}"

        if [ -z "${TEAM_ORG_ID}" ]; then
            log "WARNING: no org ID for team '${team}' — skipping."
            continue
        fi

        TEAM_UP="$(echo "${team}" | tr '[:lower:]-' '[:upper:]_')"
        TEAM_LINES+=$'\n'"# ── ${team} ──────────────────────────────────────────────────────────"$'\n'

        # Lead — org-admin (role_id=2)
        lead_email="${team}-lead@${USER_DOMAIN}"
        lead_pass=$(gen_password)
        lead_key=$(create_user "${lead_email}" "${lead_pass}" 2 "${TEAM_ORG_ID}")
        log "Created ${team} lead: ${lead_email}"
        TEAM_LINES+="# ${team} lead — role: Org Admin"$'\n'
        TEAM_LINES+="MISP_${TEAM_UP}_LEAD_EMAIL=${lead_email}"$'\n'
        TEAM_LINES+="MISP_${TEAM_UP}_LEAD_PASSWORD=${lead_pass}"$'\n'
        TEAM_LINES+="MISP_${TEAM_UP}_LEAD_KEY=${lead_key}"$'\n'

        # Regular users (role_id=3)
        for i in $(seq 1 "${USERS_PER_TEAM}"); do
            user_email="${team}-user${i}@${USER_DOMAIN}"
            user_pass=$(gen_password)
            user_key=$(create_user "${user_email}" "${user_pass}" 3 "${TEAM_ORG_ID}")
            log "Created ${team} user${i}: ${user_email}"
            TEAM_LINES+="# ${team} user${i} — role: User"$'\n'
            TEAM_LINES+="MISP_${TEAM_UP}_USER${i}_EMAIL=${user_email}"$'\n'
            TEAM_LINES+="MISP_${TEAM_UP}_USER${i}_PASSWORD=${user_pass}"$'\n'
            TEAM_LINES+="MISP_${TEAM_UP}_USER${i}_KEY=${user_key}"$'\n'
        done
    done
fi

# ── 6. Write keys file ────────────────────────────────────────────────────────

log "Writing ${KEYS_FILE} …"
{
    echo "# MISP credentials — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "# Keep this file secret."
    echo ""
    echo "MISP_BASEURL=${MISP_BASEURL:-https://localhost}"
    echo ""
    echo "# ── Service accounts ────────────────────────────────────────────────────"
    echo "# Admin (${MISP_ADMIN_EMAIL:-admin@misp.local}) — role: Site Admin"
    echo "MISP_ADMIN_KEY=${ADMIN_KEY}"
    echo ""
    if [ -n "${ADMIN2_KEY}" ]; then
        echo "# Admin2 (${MISP_ADMIN2_EMAIL:-}) — role: Site Admin"
        echo "MISP_ADMIN2_KEY=${ADMIN2_KEY}"
        echo ""
    fi
    echo "# Reader (${MISP_READER_EMAIL:-reader@misp.local}) — role: Read Only"
    echo "MISP_READER_KEY=${READER_KEY}"
    echo ""
    echo "# Writer (${MISP_WRITER_EMAIL:-writer@misp.local}) — role: Publisher"
    echo "MISP_WRITER_KEY=${WRITER_KEY}"
    printf '%s\n' "${TEAM_LINES}"
} > "${KEYS_FILE}"

chmod 600 "${KEYS_FILE}"

log "Provisioning complete."
log "Retrieve keys: docker compose exec misp cat ${KEYS_FILE}"
log "         or:   docker compose cp misp:${KEYS_FILE} ./api-keys.txt"