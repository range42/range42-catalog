#
# ISSUE 143
#
# Provisioner sidecar for mattermost/mattermost-team-edition:10.9.5.
# Runs once after Mattermost is healthy; creates users, team, and tokens.
# Pinned to 10.9.5: 10.10.x+ has an upstream mmctl panic bug (non-root UID
# resolution) that breaks the healthcheck used by depends_on.
#
FROM mattermost/mattermost-team-edition:10.9.5

USER root

# yq and jq are downloaded as static binaries — no package manager needed.
RUN wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq && \
    wget -q https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
      -O /usr/bin/jq && chmod +x /usr/bin/jq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

ENTRYPOINT ["/usr/bin/sh", "/provisioning/init.sh"]
