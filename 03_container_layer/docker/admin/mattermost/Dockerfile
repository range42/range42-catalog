#
# ISSUE 143
#
# Provisioner sidecar — runs once after Mattermost starts; creates users, team, and tokens.
#
# The mattermost:latest runtime image is distroless (no shell). This multi-stage
# build extracts mmctl from that image and runs init.sh on debian:slim instead.
#
FROM mattermost/mattermost-team-edition:latest AS mattermost-src

FROM debian:stable-slim

# mmctl is a Go binary — copy it directly from the mattermost image.
COPY --from=mattermost-src /mattermost/bin/mmctl /usr/bin/mmctl

# curl and jq come from apt. yq must be mikefarah's binary (Debian's apt yq is
# a different Python tool with incompatible syntax — do not install it from apt).
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates wget jq && \
    rm -rf /var/lib/apt/lists/*

RUN wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq

# UID 2000 matches the mattermost server process — required for Unix socket access.
RUN useradd --uid 2000 --no-create-home --shell /bin/false mattermost

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

USER mattermost
ENTRYPOINT ["/bin/sh", "/provisioning/init.sh"]
