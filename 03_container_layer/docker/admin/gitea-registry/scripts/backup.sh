#!/usr/bin/env bash
#
# ISSUE 172
#
# backup.sh — operator-side backup of the registry.
# Produces two artifacts in ./backup/ (override with BACKUP_DIR):
#   gitea-registry-data-<stamp>.tar.gz   Gitea /data volume (incl. package blobs)
#   gitea-registry-db-<stamp>.sql.gz     Postgres dump (package metadata)
#
# Both are required for a consistent restore: container blobs live in /data,
# their metadata lives in Postgres.
#
# Volume names are resolved by docker compose (project-prefixed), so this
# works regardless of the compose project name — run it from the stack dir
# or via `make backup`.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${HERE}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR:-./backup}"
mkdir -p "${OUT}"

POSTGRES_USER_VAL=$(grep -E '^POSTGRES_USER=' .env 2>/dev/null | cut -d= -f2 || true)
POSTGRES_DB_VAL=$(grep -E '^POSTGRES_DB=' .env 2>/dev/null | cut -d= -f2 || true)

echo "[backup] Archiving Gitea data volume ..."
# --user root: parts of /data (ssh host keys, log dirs) are not readable by
# the git user the provisioner image defaults to.
docker compose run --rm --no-deps --user root --entrypoint sh provisioner \
  -c 'tar czf - -C / data' > "${OUT}/gitea-registry-data-${STAMP}.tar.gz"

echo "[backup] Dumping Postgres ..."
docker compose exec -T db pg_dump -U "${POSTGRES_USER_VAL:-gitea}" "${POSTGRES_DB_VAL:-gitea}" \
  | gzip > "${OUT}/gitea-registry-db-${STAMP}.sql.gz"

echo "[backup] Done:"
ls -lh "${OUT}/gitea-registry-data-${STAMP}.tar.gz" "${OUT}/gitea-registry-db-${STAMP}.sql.gz"
