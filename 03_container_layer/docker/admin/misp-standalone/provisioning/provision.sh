#!/usr/bin/env bash
# provision.sh — orchestrates all provisioning steps in dependency order.
# Entrypoint for the provisioner service in docker-compose.yml.
set -euo pipefail

LOG_TAG="provisioner"
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

wait_for_api

/provisioning/provision-orgs.sh
/provisioning/provision-sharing-groups.sh
/provisioning/provision-users.sh
/provisioning/provision-warninglists.sh
/provisioning/provision-content.sh
/provisioning/provision-sample-events.sh

log "Provisioning complete. Credentials are in ./keys/ on the host."
