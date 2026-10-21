#!/usr/bin/env bash
# generate-cert.sh — places the TLS cert misp-nginx serves, then exits.
#
# Operator-provided cert.pem + key.pem in ./ssl/ (mounted at OPERATOR_DIR) win.
# Otherwise a self-signed cert is generated for the host in MISP_BASEURL, and
# regenerated whenever that host changes.
set -euo pipefail

CERT_DIR="/certs"
OPERATOR_DIR="/operator-certs"
HOST_MARKER="${CERT_DIR}/.host"
NGINX_UID=101
CERT_DAYS=3650

log() { echo "[generate-cert] $*" >&2; }

base_url="${MISP_BASEURL:-https://localhost}"
host="${base_url#*://}"
host="${host%%/*}"
host="${host%:*}"

if [ -f "${OPERATOR_DIR}/cert.pem" ] && [ -f "${OPERATOR_DIR}/key.pem" ]; then
    log "Using the operator-provided cert from ./ssl/"
    cp "${OPERATOR_DIR}/cert.pem" "${OPERATOR_DIR}/key.pem" "${CERT_DIR}/"
    rm -f "${HOST_MARKER}"
elif [ -f "${CERT_DIR}/cert.pem" ] && [ "$(cat "${HOST_MARKER}" 2>/dev/null)" = "${host}" ]; then
    log "Self-signed cert for ${host} already present."
else
    if [[ "${host}" =~ ^[0-9.]+$ ]]; then
        san="IP:${host},DNS:localhost,IP:127.0.0.1"
    else
        san="DNS:${host},DNS:localhost,IP:127.0.0.1"
    fi
    log "Generating a self-signed cert for ${host} (${san})"
    openssl req -x509 -nodes -days "${CERT_DAYS}" -newkey rsa:4096 \
        -keyout "${CERT_DIR}/key.pem" -out "${CERT_DIR}/cert.pem" \
        -subj "/CN=${host}/O=range42" -addext "subjectAltName=${san}" 2>/dev/null
    printf '%s' "${host}" > "${HOST_MARKER}"
fi

chown "${NGINX_UID}:${NGINX_UID}" "${CERT_DIR}/cert.pem" "${CERT_DIR}/key.pem"
chmod 644 "${CERT_DIR}/cert.pem"
chmod 600 "${CERT_DIR}/key.pem"
