#
# ISSUE 143
#

#
# BUILDER — golang:alpine (Mattermost is Go-based)
# Installs yq for YAML parsing; copies and pre-validates provisioning scripts.
#
FROM golang:alpine AS builder

# Both yq and jq are downloaded as static Linux amd64 binaries so they run
# in both the Alpine builder and the Debian-based mattermost runtime (10.9.5).
# The Alpine apk jq is musl-linked and would fail with "not found" in glibc runtimes.
RUN wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq && \
    wget -q https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
      -O /usr/bin/jq && chmod +x /usr/bin/jq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

#
# RUNTIME — pinned to 10.9.5 (same as compose.yml mattermost service).
# Copies tooling and provisioning scripts from builder.
# Acts as the provisioner sidecar: creates users via REST API (POST /api/v4/users).
# NOTE: mattermost:latest (10.10+) is distroless (no /usr/bin/env, no sh),
# so init.sh cannot exec. 10.9.5 retains a Debian base with a full shell.
#
FROM mattermost/mattermost-team-edition:10.9.5 AS runtime

COPY --from=builder /usr/bin/yq    /usr/bin/yq
COPY --from=builder /usr/bin/jq    /usr/bin/jq
COPY --from=builder /provisioning/ /provisioning/

# init.sh is already chmod +x in the builder stage; COPY --from=builder preserves
# file mode so no RUN chmod is needed here.

USER root

ENTRYPOINT ["/provisioning/init.sh"]
