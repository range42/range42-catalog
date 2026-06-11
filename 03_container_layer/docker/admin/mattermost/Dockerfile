#
# ISSUE 143
#
# Provisioner sidecar — tracks the mattermost service image.
# Runs once after Mattermost starts; creates users, team, and tokens.
#
FROM mattermost/mattermost-team-edition:latest

USER root

# yq and jq are downloaded as static binaries — no package manager needed.
RUN wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq && \
    wget -q https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
      -O /usr/bin/jq && chmod +x /usr/bin/jq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

USER mattermost
ENTRYPOINT ["/usr/bin/sh", "/provisioning/init.sh"]
