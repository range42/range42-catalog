# Headscale Ansible Role Design

**Date:** 2026-03-30
**Location:** `range42-catalog/02_ansible_layer/admin/roles/software.install.headscale/`
**Pattern:** Monolithic role (matches `software.install.tailscale`)

## Overview

An Ansible role to install, configure, and manage a [Headscale](https://github.com/juanfont/headscale) server — the self-hosted, open-source Tailscale coordination server. The role supports both system package and Docker deployment modes, manages users and pre-auth keys declaratively, and integrates with the existing `software.install.tailscale` client role by registering generated keys as Ansible facts.

## Target

- Any Debian/Ubuntu or RedHat/Fedora target (package mode: .deb for Debian, raw binary for RedHat)
- Headscale v0.28.x (latest stable)

## Role Structure

```
software.install.headscale/
├── defaults/main.yml
├── vars/main.yml
├── meta/main.yml
├── handlers/main.yml
├── tasks/
│   ├── main.yml
│   ├── install.yml
│   ├── package/
│   │   ├── install.yml
│   │   └── uninstall.yml
│   ├── docker/
│   │   ├── install.yml
│   │   └── uninstall.yml
│   ├── configure.yml
│   ├── users.yml
│   ├── preauthkeys.yml
│   ├── acl.yml
│   ├── uninstall.yml
│   └── facts.yml
├── templates/
│   ├── config.yaml.j2
│   ├── docker-compose.yml.j2
│   └── acl_policy.json.j2
└── README.md
```

## Variables

### Required

```yaml
# Install mode: "package" or "docker"
headscale_install_mode: "package"

# The public URL clients will use to reach this server
headscale_server_url: ""  # e.g. "https://headscale.example.com"

# State: "present", "latest", or "absent"
headscale_state: "present"
```

### Optional — Server Config

```yaml
headscale_version: "0.28.0"
headscale_listen_addr: "0.0.0.0:8080"
headscale_metrics_listen_addr: "0.0.0.0:9090"
headscale_grpc_listen_addr: "0.0.0.0:50443"  # verify availability in v0.28 during implementation

# IP prefixes for the tailnet
headscale_ip_prefix_v4: "100.64.0.0/10"
headscale_ip_prefix_v6: "fd7a:115c:a1e0::/48"
headscale_ip_allocation: "sequential"  # or "random"

# DNS
headscale_dns_base_domain: "headscale.local"
headscale_dns_magic_dns: true
headscale_dns_nameservers:
  - "1.1.1.1"
  - "8.8.8.8"

# DERP
headscale_derp_urls:
  - "https://controlplane.tailscale.com/derpmap/default"
headscale_derp_auto_update: true

# Database (SQLite by default — postgres is legacy/discouraged in v0.28)
headscale_database_type: "sqlite"

# Escape hatch: extra config keys merged into config.yaml
headscale_extra_config: {}
```

### Optional — User/Key Management

```yaml
# Declarative list of users to create
headscale_users: []
# Example:
# headscale_users:
#   - name: "range42-admin"
#   - name: "range42-student"

# Pre-auth keys to generate
headscale_preauthkeys: []
# Example:
# headscale_preauthkeys:
#   - user: "range42-admin"
#     reusable: true
#     ephemeral: false
#     expiration: "24h"
#     tags: ["tag:admin"]
#   - user: "range42-student"
#     reusable: true
#     ephemeral: true
#     expiration: "1h"

# Register generated keys as Ansible facts for downstream roles
headscale_register_key_facts: true

# Force regeneration of pre-auth keys even if state file has existing keys
headscale_preauthkeys_force: false

# ACL policy (JSON structure)
headscale_acl_policy: {}
```

### Optional — Docker-specific

```yaml
headscale_docker_image: "headscale/headscale"
headscale_docker_tag: "{{ headscale_version }}"
headscale_docker_data_dir: "/opt/headscale/data"
headscale_docker_config_dir: "/opt/headscale/config"
headscale_docker_compose_dir: "/opt/headscale"
```

### Optional — Package-specific

```yaml
headscale_config_dir: "/etc/headscale"
headscale_data_dir: "/var/lib/headscale"
headscale_user: "headscale"
headscale_group: "headscale"
```

### Registered Output Facts

```
headscale_url                    (string): The server URL
headscale_version_installed      (string): Installed version
headscale_users_created          (list):   Users that exist on the server
headscale_preauthkeys_generated  (dict):   Map of user name → pre-auth key string
```

The `headscale_preauthkeys_generated` dict is the integration point with the Tailscale client role:
```yaml
tailscale_authkey: "{{ headscale_preauthkeys_generated['range42-admin'] }}"
tailscale_args: "--login-server={{ headscale_url }}"
```

## Task Flow

```
1. Validate inputs
   ├── headscale_server_url must be set (unless state: absent)
   ├── headscale_install_mode must be "package" or "docker"
   └── headscale_state must be "present", "latest", or "absent"

2. Route by state
   ├── absent → uninstall.yml → STOP
   └── present/latest → continue

3. Install binary/image (don't start yet)
   ├── package mode
   │   ├── Detect OS family (Debian → .deb, RedHat/other → raw binary)
   │   ├── Download from GitHub releases (version-pinned URL)
   │   ├── Install with dpkg (Debian) or copy binary + create systemd unit (RedHat)
   │   ├── Create headscale system user/group
   │   └── For "latest": compare installed vs desired version, skip if same
   └── docker mode
       ├── Verify Docker + docker-compose are present (fail if not)
       ├── Create data/config directories
       └── Template docker-compose.yml.j2

4. Configure
   ├── Template config.yaml.j2 → config dir
   └── Set file ownership and permissions

5. Start/restart service
   ├── package → systemd enable + start (notify restart handler if config changed)
   └── docker → docker-compose up -d

6. Users (skip if headscale_users is empty)
   ├── List existing users via `headscale users list -o json`
   ├── Create missing users via `headscale users create <name>`
   └── Register headscale_users_created fact

7. Pre-auth keys (skip if headscale_preauthkeys is empty)
   ├── Check state file for previously generated keys per user
   ├── Skip generation if key already exists in state file for that user
   │   (to force regeneration: delete state file or set headscale_preauthkeys_force: true)
   ├── For new keys: `headscale preauthkeys create --user <user> [flags]`
   ├── Parse key from JSON output
   ├── Write to state file for idempotency
   └── Register headscale_preauthkeys_generated fact (dict: user → key)

8. ACL policy (skip if headscale_acl_policy is empty)
   ├── Template acl_policy.json.j2 → config dir
   └── Notify reload handler

9. Facts
   └── Register headscale_url, headscale_version_installed
```

**Docker mode note:** Steps 6-8 execute CLI commands via `docker exec` into the running container instead of directly on the host.

## Uninstall Flow (state: absent)

```
1. Detect current install mode (package or docker)
2. Stop service
   ├── package → systemctl stop + disable
   └── docker → docker-compose down
3. Remove artifacts
   ├── package → dpkg --purge / rpm -e, remove config dir, data dir, system user/group
   └── docker → remove containers, volumes, images, compose file, data/config dirs
4. Clean up state file
```

## Idempotency Notes

- **Config changes** trigger a restart via handler (not a full reinstall)
- **User creation** checks existing users first — only creates missing ones
- **Pre-auth keys** use a state file at `{{ headscale_data_dir }}/ansible-preauthkeys.json` (package mode) or `{{ headscale_docker_data_dir }}/ansible-preauthkeys.json` (Docker mode) to track generated keys per user — re-runs don't create orphan keys. The state file maps user names to their most recently generated key.
- **Version upgrades** (`state: latest`) compare installed version (via `headscale version` or container image tag) vs `headscale_version` before downloading

## Integration with Tailscale Client Role

Example playbook showing end-to-end usage:

```yaml
- name: Deploy Headscale server
  hosts: headscale_server
  roles:
    - role: software.install.headscale
      vars:
        headscale_server_url: "https://headscale.range42.local:8080"
        headscale_users:
          - name: "range42-admin"
          - name: "range42-student"
        headscale_preauthkeys:
          - user: "range42-admin"
            reusable: true
            expiration: "24h"
          - user: "range42-student"
            reusable: true
            ephemeral: true
            expiration: "1h"

- name: Connect admin VMs to Headscale
  hosts: r42_admin
  roles:
    - role: software.install.tailscale
      vars:
        tailscale_authkey: "{{ hostvars['headscale_server']['headscale_preauthkeys_generated']['range42-admin'] }}"
        tailscale_args: "--login-server={{ hostvars['headscale_server']['headscale_url'] }}"
```

## Out of Scope

- TLS termination (handled by a reverse proxy or the user's infrastructure)
- DERP server deployment (separate concern)
- Headscale web UI (e.g., headscale-ui) — could be a future companion role
