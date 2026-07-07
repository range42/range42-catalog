#
# ISSUE 142
#

#
# BUILDER — golang:alpine (same base as official Gitea Dockerfile)
# Installs yq for YAML parsing; copies and pre-validates provisioning scripts.
#
FROM golang:alpine AS builder

RUN wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq

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
COPY --from=builder /provisioning/     /provisioning/

# Install jq natively so libjq.so.1 and libonig.so.5 are present.
# The builder's jq binary is dynamically linked; copying it alone misses the libs.
# Create /tokens with git ownership so Docker seeds the named volume with
# the right permissions when the provisioner first mounts it.
# gitea CLI calls mustNotRunAsRoot(); run as git (uid 1000) so user create succeeds.
RUN apk add --no-cache jq && \
    mkdir -p /tokens && chown git:git /tokens

USER git

ENTRYPOINT ["/provisioning/init.sh"]
