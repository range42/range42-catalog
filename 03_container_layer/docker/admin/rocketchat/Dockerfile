#
# ISSUE 147
#

#
# BUILDER — node:20-alpine (same base as official Rocket.Chat Dockerfile)
#
FROM node:20-alpine AS builder

RUN apk add --no-cache yq jq

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
