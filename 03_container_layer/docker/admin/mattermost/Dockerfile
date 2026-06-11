#
# ISSUE 143
#

#
# BUILDER — golang:alpine (Mattermost is Go-based)
# Installs yq for YAML parsing; copies and pre-validates provisioning scripts.
#
FROM golang:alpine AS builder

RUN apk add --no-cache jq && \
    wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

#
# RUNTIME — mattermost/mattermost-team-edition:10.9.5 (Alpine-based, ships mattermost binary)
# Copies tooling and provisioning scripts from builder.
# Acts as the provisioner sidecar: creates users via CLI + REST API for tokens.
# Pinned to 10.9.5 to match compose.yml: mattermost 10.10.x+ has an upstream
# mmctl panic bug (non-root UID resolution) that breaks the healthcheck.
#
FROM mattermost/mattermost-team-edition:10.9.5 AS runtime

# /bin/sh is absent from the shell-less mattermost runtime image.
# Copy busybox sh from builder so init.sh can execute.
COPY --from=builder /bin/sh        /bin/sh
COPY --from=builder /usr/bin/yq    /usr/bin/yq
COPY --from=builder /usr/bin/jq    /usr/bin/jq
COPY --from=builder /provisioning/ /provisioning/

# Use exec form with an explicit /bin/sh so Docker does not rely on the
# (absent) /usr/bin/env to resolve the shebang interpreter.
USER root

ENTRYPOINT ["/bin/sh", "/provisioning/init.sh"]
