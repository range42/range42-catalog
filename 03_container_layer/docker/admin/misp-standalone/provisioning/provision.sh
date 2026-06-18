#!/usr/bin/env bash
# provision.sh — orchestrates all provisioning steps in dependency order.
# Entrypoint for the provisioner service in docker-compose.yml.
set -euo pipefail

/provisioning/provision-orgs.sh
/provisioning/provision-sharing-groups.sh
/provisioning/provision-users.sh
/provisioning/provision-warninglists.sh
/provisioning/provision-content.sh
/provisioning/provision-sample-events.sh
