#!/usr/bin/env bash
#
# ISSUE 172
#
# push-images.sh — operator-side warm-up of the internal registry.
# Builds every admin/* compose stack and pushes ALL images each stack
# references (locally built + upstream) to the Gitea registry, so a fresh
# lab VM with no internet can pull everything it needs (offline guarantee).
#
# Usage:
#   ./scripts/push-images.sh [stack ...]        # default: every ../<dir> with a compose.yml
#
# Environment:
#   REGISTRY        host:port  (default: GITEA_DOMAIN:HTTP_PORT from ./.env)
#   REGISTRY_OWNER  target namespace/org        (default: range42-admin)
#   REGISTRY_USER / REGISTRY_TOKEN
#                   if both set, docker login is performed first; otherwise an
#                   existing docker login session for REGISTRY is assumed.
#
# TLS note: for a self-signed registry, trust the cert first:
#   sudo mkdir -p /etc/docker/certs.d/<host:port>
#   make tokens   # registry-cert.pem is exported next to the tokens
#   sudo cp registry-cert.pem /etc/docker/certs.d/<host:port>/ca.crt
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # gitea-registry stack dir
ADMIN_DIR="$(cd "${HERE}/.." && pwd)"                     # 03_container_layer/docker/admin

if [ -z "${REGISTRY:-}" ]; then
  _domain=$(grep -E '^GITEA_DOMAIN=' "${HERE}/.env" 2>/dev/null | cut -d= -f2 || true)
  _port=$(grep -E '^HTTP_PORT=' "${HERE}/.env" 2>/dev/null | cut -d= -f2 || true)
  REGISTRY="${_domain:-localhost}:${_port:-3000}"
fi
REGISTRY_OWNER="${REGISTRY_OWNER:-range42-admin}"

if [ "$#" -gt 0 ]; then
  STACKS=("$@")
else
  STACKS=()
  for d in "${ADMIN_DIR}"/*/; do
    [ -f "${d}/compose.yml" ] && STACKS+=("$(basename "${d}")")
  done
fi

if [ -n "${REGISTRY_USER:-}" ] && [ -n "${REGISTRY_TOKEN:-}" ]; then
  echo "${REGISTRY_TOKEN}" | docker login "${REGISTRY}" -u "${REGISTRY_USER}" --password-stdin
fi

echo "[push-images] Target: ${REGISTRY}/${REGISTRY_OWNER}  Stacks: ${STACKS[*]}"

declare -A _seen
pushed=0
for stack in "${STACKS[@]}"; do
  dir="${ADMIN_DIR}/${stack}"
  echo ""
  echo "=== ${stack} ==="
  if ! (cd "${dir}" && docker compose build); then
    echo "[warn] build failed for ${stack} — pushing its pulled images anyway"
  fi
  images=$( (cd "${dir}" && docker compose config --images 2>/dev/null) | sort -u)
  for img in ${images}; do
    [ -n "${_seen[${img}]:-}" ] && continue
    _seen[${img}]=1
    if ! docker image inspect "${img}" >/dev/null 2>&1; then
      docker pull "${img}"
    fi
    base="${img##*/}"                     # strip registry/namespace, keep name:tag
    case "${base}" in *:*) ;; *) base="${base}:latest" ;; esac
    target="${REGISTRY}/${REGISTRY_OWNER}/${base}"
    echo "[push-images] ${img} -> ${target}"
    docker tag "${img}" "${target}"
    docker push "${target}"
    pushed=$((pushed + 1))
  done
done

echo ""
echo "[push-images] Done — ${pushed} image(s) pushed to ${REGISTRY}/${REGISTRY_OWNER}."
