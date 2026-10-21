#!/usr/bin/env bash
#
# ISSUE 172
#
# sbom-scan.sh — operator-side SBOM generation and vulnerability scan.
#
# Gitea CE has no built-in scan-on-push hook and the lab VM must stay
# offline-capable, so scanning runs on the OPERATOR machine (where internet
# and trivy are available) against the images in the registry namespace.
#
#   ./scripts/sbom-scan.sh sbom   # CycloneDX SBOM per image -> ./sbom/*.cdx.json
#                                 # + uploads each SBOM as a Gitea generic package
#   ./scripts/sbom-scan.sh scan   # trivy vulnerability report per image (stdout)
#
# Environment:
#   REGISTRY        host:port  (default: GITEA_DOMAIN:HTTP_PORT from ./.env)
#   REGISTRY_OWNER  namespace to enumerate     (default: range42-admin)
#   REGISTRY_USER / REGISTRY_TOKEN   credentials with read:package
#                                    (write:package needed for SBOM upload)
#
set -euo pipefail

MODE="${1:-sbom}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v trivy >/dev/null 2>&1; then
  echo "[sbom-scan] trivy is not installed on this machine."
  echo "            Install it (https://trivy.dev) and re-run: make ${MODE}"
  exit 1
fi

if [ -z "${REGISTRY:-}" ]; then
  _domain=$(grep -E '^GITEA_DOMAIN=' "${HERE}/.env" 2>/dev/null | cut -d= -f2 || true)
  _port=$(grep -E '^HTTP_PORT=' "${HERE}/.env" 2>/dev/null | cut -d= -f2 || true)
  REGISTRY="${_domain:-localhost}:${_port:-3000}"
fi
REGISTRY_OWNER="${REGISTRY_OWNER:-range42-admin}"
REGISTRY_USER="${REGISTRY_USER:-gitea-admin}"
REGISTRY_TOKEN="${REGISTRY_TOKEN:-}"

auth=(-u "${REGISTRY_USER}:${REGISTRY_TOKEN}")

# Enumerate container packages in the namespace via the Gitea API.
packages=$(curl -sfk "${auth[@]}" \
  "https://${REGISTRY}/api/v1/packages/${REGISTRY_OWNER}?type=container&limit=100" \
  | jq -r '.[] | "\(.name):\(.version)"')

if [ -z "${packages}" ]; then
  echo "[sbom-scan] No container packages found under ${REGISTRY_OWNER} — run make push-images first."
  exit 1
fi

mkdir -p "${HERE}/sbom"
export TRIVY_USERNAME="${REGISTRY_USER}" TRIVY_PASSWORD="${REGISTRY_TOKEN}" TRIVY_INSECURE=true

for pkg in ${packages}; do
  ref="${REGISTRY}/${REGISTRY_OWNER}/${pkg}"
  name="${pkg%%:*}"; version="${pkg##*:}"
  case "${MODE}" in
    sbom)
      out="${HERE}/sbom/${name}-${version}.cdx.json"
      echo "[sbom] ${ref} -> ${out}"
      trivy image --quiet --format cyclonedx --output "${out}" "${ref}"
      # Attach the SBOM to the registry as a generic package next to the image.
      if [ -n "${REGISTRY_TOKEN}" ]; then
        curl -sfk "${auth[@]}" -X PUT \
          --upload-file "${out}" \
          "https://${REGISTRY}/api/packages/${REGISTRY_OWNER}/generic/sbom-${name}/${version}/${name}-${version}.cdx.json" \
          >/dev/null && echo "[sbom]   attached as generic package sbom-${name}/${version}" \
          || echo "[warn]  SBOM upload failed for ${pkg} (exists already, or token lacks write:package)"
      fi
      ;;
    scan)
      echo ""
      echo "=== trivy scan: ${ref} ==="
      trivy image --quiet --severity HIGH,CRITICAL "${ref}" || true
      ;;
    *)
      echo "[sbom-scan] Unknown mode '${MODE}' (expected: sbom | scan)"; exit 1 ;;
  esac
done

echo ""
echo "[sbom-scan] Done (${MODE})."
