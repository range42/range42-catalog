#
# ISSUE 146
#

#
# BUILDER — php:8.3-apache-bookworm (same base as official Nextcloud Dockerfile)
# Installs yq and jq as static binaries; copies and pre-validates provisioning scripts.
#
FROM php:8.3-apache-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    curl -sL https://github.com/mikefarah/yq/releases/download/v4.44.1/yq_linux_amd64 \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq && \
    curl -sL https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64 \
      -o /usr/local/bin/jq && chmod +x /usr/local/bin/jq

COPY provisioning/ /provisioning/
RUN chmod +x /provisioning/init.sh

#
# RUNTIME — nextcloud:latest (PHP/Apache/Debian, provisioner via OCS API)
# Copies tooling and provisioning scripts from builder.
# Acts as the provisioner sidecar: creates users and app passwords via OCS API.
#
FROM nextcloud:latest AS runtime

COPY --from=builder /usr/local/bin/yq  /usr/local/bin/yq
COPY --from=builder /usr/local/bin/jq  /usr/local/bin/jq
COPY --from=builder /provisioning/     /provisioning/

ENTRYPOINT ["/provisioning/init.sh"]
