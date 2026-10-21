#!/usr/bin/env bash
#
# cert-gen.sh — TLS certificate management for Nextcloud nginx proxy.
# Runs as a Docker init container BEFORE nginx starts.
#
# NC_TLS_MODE:
#   disabled     → exit 0 immediately; nginx/nextcloud runs plain HTTP (default)
#   self-signed  → generate a self-signed cert into /certs/{server.crt,server.key}
#   provided     → verify operator-mounted cert files exist, then exit 0
#
set -euo pipefail

NC_TLS_MODE="${NC_TLS_MODE:-disabled}"
NC_HOST_IP="${NC_HOST_IP:-127.0.0.1}"
CERTS_DIR="/certs"

case "${NC_TLS_MODE}" in
  disabled)
    echo "[cert-gen] TLS disabled — skipping."
    exit 0
    ;;

  self-signed)
    echo "[cert-gen] Generating self-signed certificate for IP '${NC_HOST_IP}' ..."
    mkdir -p "${CERTS_DIR}"

    # Explicit OpenSSL config for SAN support (IP SANs require x509_extensions)
    CFG="$(mktemp /tmp/openssl-XXXXXX)"
    cat > "${CFG}" <<EOF
[req]
default_bits       = 4096
prompt             = no
distinguished_name = dn
x509_extensions    = san

[dn]
CN = ${NC_HOST_IP}

[san]
subjectAltName = IP:${NC_HOST_IP},IP:127.0.0.1
EOF

    openssl req -x509 -nodes -newkey rsa:4096 \
      -keyout "${CERTS_DIR}/server.key" \
      -out    "${CERTS_DIR}/server.crt" \
      -days   3650 \
      -config "${CFG}" \
      2>/dev/null
    chmod 644 "${CERTS_DIR}/server.crt"
    chmod 600 "${CERTS_DIR}/server.key"
    rm -f "${CFG}"
    echo "[cert-gen] Self-signed certificate written to ${CERTS_DIR}/server.{crt,key} (valid 10 yr)."
    ;;

  provided)
    if [[ ! -f "${CERTS_DIR}/server.crt" || ! -f "${CERTS_DIR}/server.key" ]]; then
      echo "[fatal] NC_TLS_MODE=provided but cert files not found in ${CERTS_DIR}/."
      echo "        Mount your certificate to ${CERTS_DIR}/server.crt and ${CERTS_DIR}/server.key."
      exit 1
    fi
    echo "[cert-gen] Operator-provided certificate found in ${CERTS_DIR}/."
    ;;

  *)
    echo "[fatal] Unknown NC_TLS_MODE='${NC_TLS_MODE}'. Valid values: disabled | self-signed | provided."
    exit 1
    ;;
esac
