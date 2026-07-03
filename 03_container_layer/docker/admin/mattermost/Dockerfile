#
# ISSUE 143
#
# Lightweight provisioner image — Alpine with the REST API toolchain.
# Provisioning scripts are volume-mounted at runtime (not baked in),
# mirroring the misp-standalone provisioner pattern.
#
FROM alpine:3.20

RUN apk add --no-cache bash curl jq openssl

ENTRYPOINT ["/provisioning/provision.sh"]
