#
# ISSUE 143
#

#
# BUILDER — golang:alpine
# Downloads yq (static Go binary); copies provisioning scripts.
# jq is NOT installed here — the Debian-based runtime image ships it natively.
#
FROM golang:alpine AS builder

RUN wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

#
# RUNTIME — mattermost/mattermost-team-edition:10.9.5 (Debian-based)
# The image ships sh (dash), bash, jq, and the mattermost/mmctl binaries.
# yq is absent, so we copy the static Go build from the builder stage.
# Pinned to 10.9.5: 10.10.x+ has an upstream mmctl panic bug (non-root UID
# resolution) that breaks the healthcheck used by the provisioner depends_on.
#
FROM mattermost/mattermost-team-edition:10.9.5 AS runtime

# yq is a static Go binary — no libc dependency, safe across Debian/Alpine.
COPY --from=builder /usr/bin/yq    /usr/bin/yq
COPY --from=builder /provisioning/ /provisioning/

USER root

ENTRYPOINT ["/usr/bin/sh", "/provisioning/init.sh"]
