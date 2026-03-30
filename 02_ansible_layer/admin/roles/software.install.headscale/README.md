# software.install.headscale

Ansible role to install, configure, and manage a [Headscale](https://github.com/juanfont/headscale) server — the self-hosted, open-source Tailscale coordination server.

## Features

- **Two install modes**: system package (`.deb` or binary) and Docker Compose
- **Declarative user management**: define users in variables, the role creates them idempotently
- **Pre-auth key generation**: generate keys and register them as Ansible facts for downstream Tailscale client role
- **ACL policy management**: template ACL policy from variables
- **Full lifecycle**: install, configure, upgrade (`state: latest`), uninstall (`state: absent`)
- **Idempotent**: pre-auth keys tracked in a state file to avoid creating duplicates on re-runs

## Requirements

- Ansible 2.12+
- Target: Debian/Ubuntu (`.deb` package) or any Linux (binary install)
- For Docker mode: Docker and Docker Compose must already be installed on the target
- Headscale v0.28.x

## Role Variables

### Required

| Variable | Default | Description |
|----------|---------|-------------|
| `headscale_server_url` | `""` | Public URL clients connect to (e.g., `https://headscale.example.com`) |
| `headscale_install_mode` | `"package"` | `"package"` or `"docker"` |
| `headscale_state` | `"present"` | `"present"`, `"latest"`, or `"absent"` |

### Optional — Server Config

| Variable | Default | Description |
|----------|---------|-------------|
| `headscale_version` | `"0.28.0"` | Version to install |
| `headscale_listen_addr` | `"0.0.0.0:8080"` | Server bind address |
| `headscale_metrics_listen_addr` | `"0.0.0.0:9090"` | Metrics endpoint |
| `headscale_dns_base_domain` | `"headscale.local"` | MagicDNS base domain |
| `headscale_dns_magic_dns` | `true` | Enable MagicDNS |
| `headscale_dns_nameservers` | `["1.1.1.1", "8.8.8.8"]` | Upstream DNS servers |
| `headscale_extra_config` | `{}` | Extra config keys merged into `config.yaml` |

See `defaults/main.yml` for all available variables.

### User/Key Management

| Variable | Default | Description |
|----------|---------|-------------|
| `headscale_users` | `[]` | List of users to create: `[{name: "myuser"}]` |
| `headscale_preauthkeys` | `[]` | Pre-auth keys to generate (see example below) |
| `headscale_register_key_facts` | `true` | Register generated keys as Ansible facts |
| `headscale_preauthkeys_force` | `false` | Force regeneration of all keys |

## Output Facts

After a successful run:

| Fact | Type | Description |
|------|------|-------------|
| `headscale_url` | string | The server URL |
| `headscale_version_installed` | string | Installed version |
| `headscale_users_created` | list | Users on the server |
| `headscale_preauthkeys_generated` | dict | `{user_name: key_string}` |

## Example Playbooks

### Basic — Package Mode

```yaml
- name: Deploy Headscale
  hosts: headscale_server
  roles:
    - role: software.install.headscale
      vars:
        headscale_server_url: "http://headscale.range42.local:8080"
        headscale_users:
          - name: "admin"
        headscale_preauthkeys:
          - user: "admin"
            reusable: true
            expiration: "24h"
```

### Docker Mode

```yaml
- name: Deploy Headscale (Docker)
  hosts: headscale_server
  roles:
    - role: software.install.headscale
      vars:
        headscale_install_mode: "docker"
        headscale_server_url: "http://headscale.range42.local:8080"
        headscale_users:
          - name: "admin"
```

### Integration with Tailscale Client Role

```yaml
- name: Deploy Headscale server
  hosts: headscale_server
  roles:
    - role: software.install.headscale
      vars:
        headscale_server_url: "http://headscale.range42.local:8080"
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

- name: Connect VMs to Headscale
  hosts: r42_admin
  roles:
    - role: software.install.tailscale
      vars:
        tailscale_authkey: "{{ hostvars['headscale_server']['headscale_preauthkeys_generated']['range42-admin'] }}"
        tailscale_args: "--login-server={{ hostvars['headscale_server']['headscale_url'] }}"
```

### Uninstall

```yaml
- name: Remove Headscale
  hosts: headscale_server
  roles:
    - role: software.install.headscale
      vars:
        headscale_state: "absent"
```

## License

GPL-3.0
