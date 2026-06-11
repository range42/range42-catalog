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
# RUNTIME — mattermost/mattermost-team-edition:latest (Alpine-based, ships mattermost binary)
# Copies tooling and provisioning scripts from builder.
# Acts as the provisioner sidecar: creates users via CLI + REST API for tokens.
#
FROM mattermost/mattermost-team-edition:latest AS runtime

COPY --from=builder /usr/bin/yq    /usr/bin/yq
COPY --from=builder /usr/bin/jq    /usr/bin/jq
COPY --from=builder /provisioning/ /provisioning/

# init.sh is already chmod +x in the builder stage (line 16) ; COPY --from=builder
# preserves file mode, so no RUN chmod is needed here. The mattermost runtime
# image has no /bin/sh, so a RUN at this stage would fail with
# `exec: "/bin/sh": stat /bin/sh: no such file or directory`.

USER root

ENTRYPOINT ["/provisioning/init.sh"]
