#!/usr/bin/env bash
# provision.sh — orchestrates all provisioning steps in dependency order.
# Entrypoint for the provisioner service in compose.yml.
set -euo pipefail

/provisioning/provision-users.sh
/provisioning/provision-org.sh
/provisioning/provision-tokens.sh
