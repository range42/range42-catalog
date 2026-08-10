#
# ISSUE 141
#
# Lightweight provisioner using the official Gitea image (Alpine-based).
# The Gitea CLI is available for admin user creation (direct DB access).
# Provisioning scripts are volume-mounted at runtime (not baked in),
# mirroring the misp-standalone provisioner pattern.
#
FROM gitea/gitea:latest

RUN apk add --no-cache bash openssl jq

ENTRYPOINT ["/provisioning/provision.sh"]
