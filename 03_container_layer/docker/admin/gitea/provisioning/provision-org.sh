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
#   • Optional read-only mirrors via GITEA_MIRRORS (semicolon-separated url|name pairs)
#   • Updates gitea-credentials.json with service_version, org name
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
  local body resp_body http_code
  body="$(jq -n \
    --arg u "${url}" \
    --arg n "${repo}" \
    --argjson id "${org_uid}" \
    '{"clone_addr":$u,"repo_name":$n,"uid":$id,"mirror":true,"mirror_interval":"8h0m0s","private":true,"description":"Read-only mirror — offline training content"}')"
  resp_body="$(curl -sk --max-time 120 -o /tmp/mirror_resp.json -w '%{http_code}' \
    "${AUTH[@]}" -H "Content-Type: application/json" \
    -X POST "${API}/repos/migrate" -d "${body}")"
  http_code="${resp_body}"
  case "${http_code}" in
    2*)
      echo "[provision-org]   mirror '${repo}' created (HTTP ${http_code})" ;;
    409)
      echo "[warn] Mirror '${repo}' already exists (HTTP 409) — skipping." ;;
    *)
      echo "[error] Mirror '${repo}' failed (HTTP ${http_code}): $(jq -r '.message // .' /tmp/mirror_resp.json 2>/dev/null)"
      return 0 ;;
  esac
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

# ── 6. Optional read-only mirrors ────────────────────────────────────────────
if [[ -n "${GITEA_MIRRORS}" ]]; then
  IFS=';' read -ra _MIRROR_LIST <<< "${GITEA_MIRRORS}"
  for _entry in "${_MIRROR_LIST[@]}"; do
    [[ -z "${_entry}" ]] && continue
    _mirror_url="${_entry%%|*}"
    _mirror_name="${_entry##*|}"
    maybe_create_mirror "${_mirror_url}" "${_mirror_name}"
  done
fi

# ── 8. Sample repository seeding ─────────────────────────────────────────────
# Creates a "hello-range42" training repo under the org with:
#   • 2 feature branches, pre-defined labels & milestones, open issues, open PRs
#   • Branch protection on main (1 required approval)
#   • Topics for discoverability
#   • Optional webhook if GITEA_WEBHOOK_URL is set
#   • Repo added to all teams (instructors + per-team write teams)
echo "[provision-org] Seeding sample repository 'hello-range42' ..."
SAMPLE_REPO="hello-range42"
create_repo "${SAMPLE_REPO}" "Range42 training sandbox — branches, issues, and pull-request workflow"

# Labels
echo "[provision-org]   labels ..."
LBL_BUG="$(create_label "${SAMPLE_REPO}" "bug"         "#d73a4a")"
LBL_ENH="$(create_label "${SAMPLE_REPO}" "enhancement" "#a2eeef")"
LBL_EXE="$(create_label "${SAMPLE_REPO}" "exercise"    "#7057ff")"
LBL_BLK="$(create_label "${SAMPLE_REPO}" "blocked"     "#e4e669")" ; : "${LBL_BLK}"  # label exists for trainee self-tagging

# Milestones
echo "[provision-org]   milestones ..."
MS1="$(create_milestone "${SAMPLE_REPO}" "Sprint 1")"
MS2="$(create_milestone "${SAMPLE_REPO}" "Sprint 2")"

# Feature branches + file commits
echo "[provision-org]   branches and commits ..."
create_branch "${SAMPLE_REPO}" "feature/add-docs"
commit_file "${SAMPLE_REPO}" "feature/add-docs" "docs/CONTRIBUTING.md" \
  "# Contributing

Welcome to the Range42 training repo.  Open a pull request from your feature
branch and request a review before merging into \`main\`.

## Workflow

1. Create a branch: \`git checkout -b feature/<your-task>\`
2. Commit your changes
3. Push and open a PR
4. Request a review from your instructor
" \
  "docs: add CONTRIBUTING guide"

create_branch "${SAMPLE_REPO}" "feature/exercise-01"
commit_file "${SAMPLE_REPO}" "feature/exercise-01" "exercises/01-hello-git.md" \
  "# Exercise 01 — Hello Git

## Objective

Practice the basic Git workflow inside the Range42 Gitea instance.

## Steps

1. Clone this repository using your SSH key
2. Create a branch named \`solution/<your-username>\`
3. Add a file \`answers/01-hello-git.txt\` with your name and the current date
4. Commit and push your branch
5. Open a pull request targeting \`main\`

## Acceptance criteria

- [ ] Branch exists and is named correctly
- [ ] File \`answers/01-hello-git.txt\` is present
- [ ] Pull request is open and assigned to your instructor
" \
  "exercises: add exercise 01 hello-git"

# Issues
echo "[provision-org]   issues ..."
create_issue "${SAMPLE_REPO}" \
  "Exercise 01: Hello Git workflow" \
  "Complete the steps in \`exercises/01-hello-git.md\` and open a pull request." \
  "${LBL_EXE}" "${MS1}"

create_issue "${SAMPLE_REPO}" \
  "Add setup instructions to README" \
  "The repository README is missing SSH clone instructions and a link to the contributing guide." \
  "${LBL_ENH}" "${MS1}"

create_issue "${SAMPLE_REPO}" \
  "SSH key upload fails for some trainees" \
  "Some trainees reported that \`git clone\` returns 'Permission denied (publickey)'.  Verify their SSH keys are uploaded correctly in Gitea." \
  "${LBL_BUG}" "${MS2}"

# Pull requests (one per feature branch)
echo "[provision-org]   pull requests ..."
create_pr "${SAMPLE_REPO}" "feature/add-docs" \
  "docs: add CONTRIBUTING guide" \
  "Adds a step-by-step contribution guide so trainees understand the review-then-merge workflow before starting exercises."

create_pr "${SAMPLE_REPO}" "feature/exercise-01" \
  "exercises: add exercise 01 — hello git" \
  "Introduces the first hands-on exercise covering the basic Git workflow (branch → commit → push → PR)."

# Branch protection on main
echo "[provision-org]   branch protection on main ..."
protect_main "${SAMPLE_REPO}"

# Topics
echo "[provision-org]   topics ..."
set_topics "${SAMPLE_REPO}" "training" "range42" "exercise" "git-workflow"

# Webhook (optional)
maybe_create_webhook "${SAMPLE_REPO}" "${GITEA_WEBHOOK_URL}"

# Grant all teams access to the sample repo
echo "[provision-org]   adding repo to teams ..."
add_repo_to_team "${INSTRUCTORS_TEAM_ID}" "${SAMPLE_REPO}"
IFS=',' read -ra _SAMPLE_TEAMS <<< "${GITEA_TEAMS}"
for _t in "${_SAMPLE_TEAMS[@]}"; do
  _tid="$(get_team_id "${_t}")"
  [[ -n "${_tid}" ]] && add_repo_to_team "${_tid}" "${SAMPLE_REPO}" || true
done

echo "[provision-org] Sample repository '${SAMPLE_REPO}' seeded."

# ── 7. Update credentials JSON with org metadata ──────────────────────────────
echo "[provision-org] Updating credentials JSON ..."
gitea_version="$(_get "/version" 2>/dev/null | jq -r '.version // "unknown"')"
provisioned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq  --arg ver "${gitea_version}" \
    --arg ts  "${provisioned_at}" \
    --arg org "${GITEA_ORG_NAME}" \
    '. + {"service_version":$ver,"provisioned_at":$ts,"org":$org}' \
    "${CREDS_FILE}" > "${CREDS_FILE}.tmp" \
  && mv "${CREDS_FILE}.tmp" "${CREDS_FILE}"
chmod 600 "${CREDS_FILE}"

touch "${ORG_STAMP}"
echo "[provision-org] Done. Organisation '${GITEA_ORG_NAME}' seeded."
