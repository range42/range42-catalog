#
# ISSUE 143
#
# Provisioner sidecar — runs once after Mattermost starts; creates users, team, and tokens.
#
# The mattermost:latest runtime image is distroless (no shell). This multi-stage
# build extracts mmctl from that image and runs init.sh on debian:slim instead.
#
FROM mattermost/mattermost-team-edition:latest AS mattermost-src

FROM debian:12-slim

# mmctl is a Go binary — copy it directly from the mattermost image.
COPY --from=mattermost-src /mattermost/bin/mmctl /usr/bin/mmctl

# curl is needed for REST API calls. yq and jq are downloaded as static binaries.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates wget && \
    rm -rf /var/lib/apt/lists/*

RUN wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq && \
    wget -q https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
      -O /usr/bin/jq && chmod +x /usr/bin/jq

# UID 2000 matches the mattermost server process — required for Unix socket access.
RUN useradd --uid 2000 --no-create-home --shell /bin/false mattermost

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

USER mattermost
ENTRYPOINT ["/bin/sh", "/provisioning/init.sh"]
