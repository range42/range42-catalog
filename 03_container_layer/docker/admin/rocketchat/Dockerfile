#
# ISSUE 147
#

#
# BUILDER — node:20-alpine (same base as official Rocket.Chat Dockerfile)
#
FROM node:20-alpine AS builder

RUN apk add --no-cache jq && \
    wget -q https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -O /usr/bin/yq && chmod +x /usr/bin/yq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

#
# RUNTIME — rocketchat/rocket.chat:latest (Alpine/Node-based)
#
FROM rocketchat/rocket.chat:latest AS runtime

USER root

COPY --from=builder /usr/bin/yq    /usr/bin/yq
COPY --from=builder /usr/bin/jq    /usr/bin/jq
COPY --from=builder /provisioning/ /provisioning/

ENTRYPOINT ["/provisioning/init.sh"]
