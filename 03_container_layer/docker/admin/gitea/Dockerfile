#
# ISSUE 141
#

#
# BUILDER — golang:alpine (same base as official Gitea Dockerfile)
# Installs yq for YAML parsing; copies and pre-validates provisioning scripts.
#
FROM golang:alpine AS builder

RUN apk add --no-cache jq && \
    wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

#
# RUNTIME — gitea/gitea:latest (Alpine-based, ships the gitea CLI)
# Copies tooling and provisioning scripts from builder.
# Acts as the provisioner sidecar: creates users via CLI + SSH keys via REST API.
#
FROM gitea/gitea:latest AS runtime

COPY --from=builder /usr/bin/yq        /usr/bin/yq
COPY --from=builder /usr/bin/jq        /usr/bin/jq
COPY --from=builder /provisioning/     /provisioning/

ENTRYPOINT ["/provisioning/init.sh"]
