#!/usr/bin/env bash
#
# ISSUE 171
#
# cert-gen.sh — TLS certificate management for Gitea.
# Runs as a Docker init container (provisioner image) BEFORE Gitea starts.
#
# GITEA_TLS_MODE:
#   disabled     → exit 0 immediately; Gitea runs plain HTTP (default)
#   self-signed  → generate a self-signed cert into /certs/{server.crt,server.key}
#   provided     → verify operator-mounted cert files exist, then exit 0
#
set -euo pipefail

GITEA_TLS_MODE="${GITEA_TLS_MODE:-disabled}"
DOMAIN="${GITEA_DOMAIN:-localhost}"
CERTS_DIR="/certs"

case "${GITEA_TLS_MODE}" in
  disabled)
    echo "[cert-gen] TLS disabled — skipping."
    exit 0
    ;;

  self-signed)
    echo "[cert-gen] Generating self-signed certificate for '${DOMAIN}' ..."
    mkdir -p "${CERTS_DIR}"

    # Use an explicit config file for SAN support (portable across OpenSSL versions)
    CFG="$(mktemp /tmp/openssl-XXXXXX)"
    cat > "${CFG}" <<EOF
[req]
default_bits       = 4096
prompt             = no
distinguished_name = dn
x509_extensions    = san

[dn]
CN = ${DOMAIN}

[san]
subjectAltName = DNS:${DOMAIN},DNS:gitea,IP:127.0.0.1
EOF

    openssl req -x509 -nodes -newkey rsa:4096 \
      -keyout "${CERTS_DIR}/server.key" \
      -out    "${CERTS_DIR}/server.crt" \
      -days   3650 \
      -config "${CFG}" \
      2>/dev/null
    chmod 600 "${CERTS_DIR}/server.key"
    rm -f "${CFG}"
    echo "[cert-gen] Self-signed certificate written to ${CERTS_DIR}/server.{crt,key} (valid 10 yr)."
    ;;

  provided)
    if [[ ! -f "${CERTS_DIR}/server.crt" || ! -f "${CERTS_DIR}/server.key" ]]; then
      echo "[fatal] GITEA_TLS_MODE=provided but cert files not found in ${CERTS_DIR}/."
      echo "        Mount your certificate to ${CERTS_DIR}/server.crt and ${CERTS_DIR}/server.key."
      exit 1
    fi
    echo "[cert-gen] Operator-provided certificate found in ${CERTS_DIR}/."
    ;;

  *)
    echo "[fatal] Unknown GITEA_TLS_MODE='${GITEA_TLS_MODE}'. Valid values: disabled | self-signed | provided."
    exit 1
    ;;
esac
