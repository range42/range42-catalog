#
# ISSUE 142
#

#
# BUILDER — golang:alpine (same base as official Gitea Dockerfile)
# Installs yq for YAML parsing; copies and pre-validates provisioning scripts.
#
FROM golang:alpine AS builder

RUN apk add --no-cache yq jq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

#
# RUNTIME — gitea/gitea:latest (Alpine-based, ships the gitea CLI)
# Copies tooling and provisioning scripts from builder.
# Acts as the provisioner sidecar: creates users via CLI + SSH keys via REST API
# and generates personal access tokens for Docker registry usage.
#
FROM gitea/gitea:latest AS runtime

COPY --from=builder /usr/bin/yq        /usr/bin/yq
COPY --from=builder /usr/bin/jq        /usr/bin/jq
COPY --from=builder /provisioning/     /provisioning/

ENTRYPOINT ["/provisioning/init.sh"]
