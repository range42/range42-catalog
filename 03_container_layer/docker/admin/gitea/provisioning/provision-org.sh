#!/usr/bin/env bash
#
# ISSUE 171
#
# provision-org.sh — seeds the Range42 training organisation in Gitea:
#
#   • Organisation creation (GITEA_ORG_NAME, default: range42-training)
#   • Gitea teams:
#       – instructors  (owner permission) ← admin + all instructors
#       – one team per entry in GITEA_TEAMS (write permission) ← lead + users
#   • Two sample repositories seeded under the org:
#       – workshop-linux-basics
#       – workshop-ctf-intro
#     Each repo gets:
#       – Labels:      exercise, hint, solution, bug, in-progress
#       – Milestones:  Day 1, Day 2
#       – Issues with label + milestone assignments
#       – Feature branch + file commit → PR (demonstrates review workflow)
#       – Branch protection on main (require 1 approving review, no direct push)
#       – Topics (tags) on the repo
#       – Optional webhook if GITEA_WEBHOOK_URL is set
#       – Added to instructors team and per-team Gitea teams
#   • Updates gitea-credentials.json with service_version, org name, sample_repos
#
# Requires provision-users.sh to have completed successfully first
# (reads gitea-credentials.json for the base URL).
#
# Idempotency stamp: /tokens/.org-provisioned
#
set -euo pipefail

GITEA_URL="${GITEA_URL:-http://gitea:3000}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-Admin1234!}"
GITEA_TEAMS="${GITEA_TEAMS:-team-blue,team-red}"
GITEA_INSTRUCTOR_COUNT="${GITEA_INSTRUCTOR_COUNT:-1}"
GITEA_USERS_PER_TEAM="${GITEA_USERS_PER_TEAM:-2}"
GITEA_ORG_NAME="${GITEA_ORG_NAME:-range42-training}"
GITEA_WEBHOOK_URL="${GITEA_WEBHOOK_URL:-}"
# Semicolon-separated list of "url|repo-name" pairs, e.g.:
#   GITEA_MIRRORS=https://github.com/org/repo|repo-name;https://github.com/org2/repo2|repo2
GITEA_MIRRORS="${GITEA_MIRRORS:-}"
TOKENS_DIR="/tokens"
CREDS_FILE="${TOKENS_DIR}/gitea-credentials.json"
ORG_STAMP="${TOKENS_DIR}/.org-provisioned"

API="${GITEA_URL}/api/v1"
AUTH=(-u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}")

# ── 1. Idempotency guard ─────────────────────────────────────────────────────
if [[ -f "${ORG_STAMP}" ]]; then
  echo "[provision-org] Already provisioned (stamp found). Exiting."
  exit 0
fi

echo "[provision-org] Seeding organisation '${GITEA_ORG_NAME}' ..."

# ── 2. HTTP helpers ───────────────────────────────────────────────────────────
_get() {
  curl -sfk "${AUTH[@]}" -H "Content-Type: application/json" \
    "${API}${1}"
}

_post() {
  local ep="${1}"; shift
  curl -sfk "${AUTH[@]}" -H "Content-Type: application/json" \
    -X POST "${API}${ep}" "$@"
}

_put() {
  local ep="${1}"; shift
  curl -sfk "${AUTH[@]}" -H "Content-Type: application/json" \
    -X PUT "${API}${ep}" "$@"
}

b64() {
  # base64-encode a string; strip newlines for the Gitea contents API
  printf '%s' "${1}" | base64 | tr -d '\n'
}

get_team_id() {
  _get "/orgs/${GITEA_ORG_NAME}/teams" 2>/dev/null \
    | jq -r --arg n "${1}" '.[] | select(.name==$n) | .id // empty'
}

get_or_create_team() {
  local tname="${1}" perm="${2}"
  local tid
  tid="$(get_team_id "${tname}")"
  if [[ -z "${tid}" ]]; then
    tid="$(_post "/orgs/${GITEA_ORG_NAME}/teams" -d "$(jq -n \
        --arg n "${tname}" --arg p "${perm}" \
        '{"name":$n,"permission":$p,"units":["repo.code","repo.issues","repo.pulls","repo.wiki","repo.releases"]}')" \
      | jq -r '.id')"
  fi
  printf '%s' "${tid}"
}

# ── 3. Organisation ───────────────────────────────────────────────────────────
echo "[provision-org] Creating org '${GITEA_ORG_NAME}' ..."
_post "/orgs" -d "$(jq -n \
  --arg n "${GITEA_ORG_NAME}" \
  '{"username":$n,"visibility":"private","description":"Range42 training — exercise repositories"}')" \
  >/dev/null 2>&1 || echo "[warn] Org '${GITEA_ORG_NAME}' may already exist — continuing."

# ── 4. Teams ──────────────────────────────────────────────────────────────────
echo "[provision-org] Creating 'instructors' team (owner permission) ..."
INSTRUCTORS_TEAM_ID="$(get_or_create_team "instructors" "owner")"
_put "/teams/${INSTRUCTORS_TEAM_ID}/members/${GITEA_ADMIN_USER}" >/dev/null 2>&1 || true

i=1
while [[ "${i}" -le "${GITEA_INSTRUCTOR_COUNT}" ]]; do
  uname="instructor-$(printf '%02d' "${i}")"
  echo "[provision-org]   + ${uname} → instructors"
  _put "/teams/${INSTRUCTORS_TEAM_ID}/members/${uname}" >/dev/null 2>&1 || true
  i=$((i + 1))
done

IFS=',' read -ra TEAM_LIST <<< "${GITEA_TEAMS}"
for team in "${TEAM_LIST[@]}"; do
  echo "[provision-org] Creating team '${team}' (write permission) ..."
  tid="$(get_or_create_team "${team}" "write")"
  _put "/teams/${tid}/members/${team}-lead" >/dev/null 2>&1 || true
  u=1
  while [[ "${u}" -le "${GITEA_USERS_PER_TEAM}" ]]; do
    _put "/teams/${tid}/members/${team}-user-$(printf '%02d' "${u}")" >/dev/null 2>&1 || true
    u=$((u + 1))
  done
done

# ── 5. Repository helpers ─────────────────────────────────────────────────────
create_repo() {
  local repo="${1}" desc="${2}"
  echo "[provision-org] Creating repo '${GITEA_ORG_NAME}/${repo}' ..."
  _post "/orgs/${GITEA_ORG_NAME}/repos" -d "$(jq -n \
    --arg n "${repo}" --arg d "${desc}" \
    '{"name":$n,"description":$d,"auto_init":true,"default_branch":"main","private":true}')" \
    >/dev/null 2>&1 || echo "[warn] Repo '${repo}' may already exist."
  # Give Gitea time to finish the auto_init commit before we push branches/files
  sleep 2
}

create_label() {
  local repo="${1}" name="${2}" color="${3}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/labels" \
    -d "$(jq -n --arg n "${name}" --arg c "${color}" '{"name":$n,"color":$c}')" \
    | jq -r '.id // 0'
}

create_milestone() {
  local repo="${1}" title="${2}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/milestones" \
    -d "$(jq -n --arg t "${title}" '{"title":$t}')" \
    | jq -r '.id // 0'
}

create_issue() {
  local repo="${1}" title="${2}" body="${3}" label_id="${4}" milestone_id="${5}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/issues" -d "$(jq -n \
    --arg  t "${title}" \
    --arg  b "${body}" \
    --argjson l "[${label_id}]" \
    --argjson m "${milestone_id}" \
    '{"title":$t,"body":$b,"labels":$l,"milestone":$m}')" >/dev/null
}

create_branch() {
  local repo="${1}" branch="${2}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/branches" -d "$(jq -n \
    --arg b "${branch}" --arg o "main" \
    '{"new_branch_name":$b,"old_branch_name":$o}')" >/dev/null
}

commit_file() {
  local repo="${1}" branch="${2}" path="${3}" content="${4}" msg="${5}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/contents/${path}" -d "$(jq -n \
    --arg c "$(b64 "${content}")" \
    --arg m "${msg}" \
    --arg b "${branch}" \
    '{"content":$c,"message":$m,"branch":$b}')" >/dev/null
}

create_pr() {
  local repo="${1}" head="${2}" title="${3}" body="${4}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/pulls" -d "$(jq -n \
    --arg h "${head}" --arg t "${title}" --arg b "${body}" \
    '{"title":$t,"head":$h,"base":"main","body":$b}')" >/dev/null
}

protect_main() {
  local repo="${1}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/branch_protections" -d \
    '{"branch_name":"main","enable_push":false,"required_approvals":1}' >/dev/null
}

set_topics() {
  local repo="${1}"; shift
  local topics_json
  topics_json="$(printf '%s\n' "$@" | jq -Rn '[inputs]')"
  _put "/repos/${GITEA_ORG_NAME}/${repo}/topics" \
    -d "{\"topics\":${topics_json}}" >/dev/null
}

add_repo_to_team() {
  local tid="${1}" repo="${2}"
  _put "/teams/${tid}/repos/${GITEA_ORG_NAME}/${repo}" >/dev/null 2>&1 || true
}

maybe_create_mirror() {
  local url="${1}" repo="${2}"
  [[ -z "${url}" ]] && return 0
  echo "[provision-org]   + mirror '${repo}' ← ${url}"
  local org_uid
  org_uid="$(_get "/orgs/${GITEA_ORG_NAME}" 2>/dev/null | jq -r '.id // empty')"
  if [[ -z "${org_uid}" ]]; then
    echo "[warn] Could not resolve org UID for '${GITEA_ORG_NAME}' — skipping mirror."
    return 0
  fi
  _post "/repos/migrate" -d "$(jq -n \
    --arg u "${url}" \
    --arg n "${repo}" \
    --argjson id "${org_uid}" \
    '{"clone_url":$u,"repo_name":$n,"uid":$id,"mirror":true,"mirror_interval":"8h0m0s","private":true,"description":"Read-only mirror — offline training content"}')" \
    >/dev/null 2>&1 || echo "[warn] Mirror '${repo}' may already exist — skipping."
  local tid
  tid="$(get_team_id "instructors")"
  [[ -n "${tid}" ]] && add_repo_to_team "${tid}" "${repo}" || true
  IFS=',' read -ra _MIRROR_TEAMS <<< "${GITEA_TEAMS}"
  for _t in "${_MIRROR_TEAMS[@]}"; do
    tid="$(get_team_id "${_t}")"
    [[ -n "${tid}" ]] && add_repo_to_team "${tid}" "${repo}" || true
  done
}

maybe_create_webhook() {
  local repo="${1}" url="${2}"
  [[ -z "${url}" ]] && return 0
  echo "[provision-org]   + webhook → ${url}"
  _post "/repos/${GITEA_ORG_NAME}/${repo}/hooks" -d "$(jq -n \
    --arg u "${url}" \
    '{"type":"gitea","config":{"url":$u,"content_type":"json"},"events":["push","pull_request","issues"],"active":true}')" \
    >/dev/null
}

# ── 6a. workshop-linux-basics ─────────────────────────────────────────────────
REPO1="workshop-linux-basics"
create_repo "${REPO1}" "Introduction to Linux — hands-on exercises for the cyber range"

echo "[provision-org] Seeding labels, milestones, issues for '${REPO1}' ..."
L1_EXERCISE="$(create_label "${REPO1}" "exercise"    "#4a90d9")"
L1_HINT="$(    create_label "${REPO1}" "hint"         "#f5a623")"
L1_SOLUTION="$(create_label "${REPO1}" "solution"     "#7ed321")"
L1_BUG="$(     create_label "${REPO1}" "bug"          "#e11d48")"
L1_WIP="$(     create_label "${REPO1}" "in-progress"  "#9013fe")"

M1_DAY1="$(create_milestone "${REPO1}" "Day 1 — Fundamentals")"
M1_DAY2="$(create_milestone "${REPO1}" "Day 2 — Advanced")"

create_issue "${REPO1}" \
  "Task: Upload your SSH public key" \
  "Before cloning this repository, upload your SSH public key to your Gitea profile.

Go to **Settings → SSH / GPG Keys → Add Key** and paste your \`~/.ssh/id_ed25519.pub\`.

Once added, test the connection with: \`ssh -T git@<gitea-host>\`" \
  "${L1_EXERCISE}" "${M1_DAY1}"

create_issue "${REPO1}" \
  "Task: Clone the repository using SSH" \
  "Clone this repository to your workstation using the SSH clone URL shown on the repository page.

\`\`\`bash
git clone git@<gitea-host>:${GITEA_ORG_NAME}/${REPO1}.git
cd ${REPO1}
\`\`\`" \
  "${L1_EXERCISE}" "${M1_DAY1}"

create_issue "${REPO1}" \
  "Challenge: Fix the broken Bash script" \
  "The script \`exercises/01_permissions/fix_me.sh\` contains a bug that prevents it from running.

Find and fix the bug, then open a pull request against \`main\` with your fix.
Label your PR **in-progress** while working on it." \
  "${L1_BUG}" "${M1_DAY2}"

echo "[provision-org] Creating feature branch + PR for '${REPO1}' ..."
create_branch "${REPO1}" "feature/add-contributing-guide"
commit_file "${REPO1}" "feature/add-contributing-guide" "CONTRIBUTING.md" \
"# Contributing

All contributions to this repository require **at least one approving review** before
they can be merged into \`main\`.

## Workflow

1. Branch from \`main\`  (\`git checkout -b feature/your-change\`)
2. Commit your changes
3. Push the branch and open a pull request
4. Assign a reviewer
5. Address any feedback
6. Reviewer approves → merge

## Commit message format

Use the imperative mood: *fix permissions on script*, *add exercise 02*, etc.
" \
  "docs: add contributing guide"

create_pr "${REPO1}" "feature/add-contributing-guide" \
  "docs: add contributing guide (review-then-merge demo)" \
  "Demonstrates the branch-protection workflow: \`main\` requires at least **1 approving review** before a merge is permitted.

*This PR is pre-seeded for training purposes — review and merge it to practise the approval flow.*"

protect_main "${REPO1}"
set_topics "${REPO1}" "linux" "beginner" "workshop" "range42"
maybe_create_webhook "${REPO1}" "${GITEA_WEBHOOK_URL}"
add_repo_to_team "${INSTRUCTORS_TEAM_ID}" "${REPO1}"

# ── 6b. workshop-ctf-intro ────────────────────────────────────────────────────
REPO2="workshop-ctf-intro"
create_repo "${REPO2}" "CTF introduction — flag-hunting exercises for the cyber range"

echo "[provision-org] Seeding labels, milestones, issues for '${REPO2}' ..."
L2_EXERCISE="$(create_label "${REPO2}" "exercise"    "#4a90d9")"
L2_HINT="$(    create_label "${REPO2}" "hint"         "#f5a623")"
L2_SOLUTION="$(create_label "${REPO2}" "solution"     "#7ed321")"
L2_BUG="$(     create_label "${REPO2}" "bug"          "#e11d48")"
L2_WIP="$(     create_label "${REPO2}" "in-progress"  "#9013fe")"

M2_DAY1="$(create_milestone "${REPO2}" "Day 1 — Recon")"
M2_DAY2="$(create_milestone "${REPO2}" "Day 2 — Exploitation")"

create_issue "${REPO2}" \
  "Challenge: Find the hidden flag in the HTTP headers" \
  "A flag has been embedded in the HTTP response headers of the target web service.

Use your browser's Developer Tools (Network tab) or \`curl -I http://<target>\` to inspect the response headers and locate the flag." \
  "${L2_EXERCISE}" "${M2_DAY1}"

create_issue "${REPO2}" \
  "Hint: web challenge 01 — where to look" \
  "Check the \`X-Flag\` and \`Server\` response headers carefully.

Also inspect Set-Cookie values — flags are sometimes hidden in cookie attributes." \
  "${L2_HINT}" "${M2_DAY1}"

create_issue "${REPO2}" \
  "Challenge: Exploit path traversal to read /etc/passwd" \
  "The target application does not sanitise user-supplied file paths.

Demonstrate a path traversal attack that reads \`/etc/passwd\` from the server.

Document your exploit in a write-up and open a PR using the template in \`writeup/TEMPLATE.md\`.
Label your PR **in-progress** while working on it." \
  "${L2_EXERCISE}" "${M2_DAY2}"

echo "[provision-org] Creating feature branch + PR for '${REPO2}' ..."
create_branch "${REPO2}" "feature/add-writeup-template"
commit_file "${REPO2}" "feature/add-writeup-template" "writeup/TEMPLATE.md" \
"# CTF Challenge Write-up Template

## Challenge name

## Category

<!-- e.g. Web, Pwn, Crypto, Forensics, Misc -->

## Difficulty

<!-- Easy / Medium / Hard -->

## Description

<!-- Paste the challenge description here -->

## Reconnaissance

<!-- What did you find during recon? -->

## Solution

### Step 1

### Step 2

### Step 3

## Flag

\`\`\`
FLAG{...}
\`\`\`

## Lessons learned

<!-- What would you do differently next time? -->
" \
  "docs: add CTF write-up template"

create_pr "${REPO2}" "feature/add-writeup-template" \
  "docs: add CTF write-up template (review-then-merge demo)" \
  "Adds a standard write-up template for trainees to document their solutions.

Requires review before merge — demonstrating the protected \`main\` branch workflow.

*This PR is pre-seeded for training purposes — review and merge it to practise the approval flow.*"

protect_main "${REPO2}"
set_topics "${REPO2}" "ctf" "security" "workshop" "range42"
maybe_create_webhook "${REPO2}" "${GITEA_WEBHOOK_URL}"
add_repo_to_team "${INSTRUCTORS_TEAM_ID}" "${REPO2}"

# Add both repos to every per-team Gitea team
for team in "${TEAM_LIST[@]}"; do
  tid="$(get_team_id "${team}")"
  if [[ -n "${tid}" ]]; then
    add_repo_to_team "${tid}" "${REPO1}"
    add_repo_to_team "${tid}" "${REPO2}"
  fi
done

# ── 7. Optional read-only mirrors ────────────────────────────────────────────
if [[ -n "${GITEA_MIRRORS}" ]]; then
  IFS=';' read -ra _MIRROR_LIST <<< "${GITEA_MIRRORS}"
  for _entry in "${_MIRROR_LIST[@]}"; do
    [[ -z "${_entry}" ]] && continue
    _mirror_url="${_entry%%|*}"
    _mirror_name="${_entry##*|}"
    maybe_create_mirror "${_mirror_url}" "${_mirror_name}"
  done
fi

# ── 8. Update credentials JSON with org metadata ──────────────────────────────
echo "[provision-org] Updating credentials JSON ..."
gitea_version="$(_get "/version" 2>/dev/null | jq -r '.version // "unknown"')"
provisioned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq  --arg ver "${gitea_version}" \
    --arg ts  "${provisioned_at}" \
    --arg org "${GITEA_ORG_NAME}" \
    --arg r1  "${REPO1}" \
    --arg r2  "${REPO2}" \
    '. + {"service_version":$ver,"provisioned_at":$ts,"org":$org,"sample_repos":[$r1,$r2]}' \
    "${CREDS_FILE}" > "${CREDS_FILE}.tmp" \
  && mv "${CREDS_FILE}.tmp" "${CREDS_FILE}"
chmod 600 "${CREDS_FILE}"

touch "${ORG_STAMP}"
echo "[provision-org] Done. Organisation '${GITEA_ORG_NAME}' seeded with ${REPO1}, ${REPO2}."
