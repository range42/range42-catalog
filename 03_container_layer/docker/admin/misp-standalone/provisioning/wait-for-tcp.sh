#!/usr/bin/env bash
# Usage: wait-for-tcp.sh <host> <port> [timeout_seconds]
set -euo pipefail

HOST="${1:?host required}"
PORT="${2:?port required}"
TIMEOUT="${3:-60}"

end=$((SECONDS + TIMEOUT))

until (exec 3<>"/dev/tcp/${HOST}/${PORT}") 2>/dev/null; do
    if [ "${SECONDS}" -ge "${end}" ]; then
        echo "[wait] Timeout after ${TIMEOUT}s waiting for ${HOST}:${PORT}" >&2
        exit 1
    fi
    echo "[wait] ${HOST}:${PORT} not ready — retrying …"
    sleep 3
done

exec 3>&-
echo "[wait] ${HOST}:${PORT} is up"
