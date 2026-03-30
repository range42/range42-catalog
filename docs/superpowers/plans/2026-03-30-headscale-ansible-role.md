# Headscale Ansible Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an Ansible role `software.install.headscale` that installs, configures, and manages a Headscale v0.28.x server with both package and Docker modes, declarative user/key management, and downstream Tailscale client integration.

**Architecture:** Single monolithic role following the `software.install.tailscale` pattern. Entry point validates inputs, routes to install mode (package or docker), templates config, starts service, then manages users/keys/ACLs. Pre-auth keys are tracked in a state file for idempotency and registered as Ansible facts for consumption by the Tailscale client role.

**Tech Stack:** Ansible 2.12+, Headscale v0.28.x, systemd, Docker Compose (optional), Jinja2 templates

**Spec:** `docs/superpowers/specs/2026-03-30-headscale-ansible-role-design.md`

---

## File Structure

All files are created under `range42-catalog/02_ansible_layer/admin/roles/software.install.headscale/`.

| File | Responsibility |
|------|---------------|
| `defaults/main.yml` | All user-configurable variables with sensible defaults |
| `vars/main.yml` | Internal constants: download URLs, paths, OS-family mappings |
| `meta/main.yml` | Role metadata, supported platforms, dependencies |
| `handlers/main.yml` | Restart and reload handlers for both package and docker modes |
| `tasks/main.yml` | Entry point: validate → route by state → orchestrate |
| `tasks/install.yml` | Dispatch to package/ or docker/ based on install mode |
| `tasks/package/install.yml` | Download .deb or binary from GitHub, install, create user/group |
| `tasks/package/uninstall.yml` | Stop service, purge package/binary, remove dirs and user |
| `tasks/docker/install.yml` | Pull image, create dirs, template compose file |
| `tasks/docker/uninstall.yml` | docker-compose down, remove dirs/volumes/images |
| `tasks/configure.yml` | Template config.yaml, set permissions |
| `tasks/start.yml` | Enable + start service (systemd or docker-compose) |
| `tasks/users.yml` | Idempotently create users via headscale CLI |
| `tasks/preauthkeys.yml` | Generate pre-auth keys, track in state file, register facts |
| `tasks/acl.yml` | Template ACL policy file, notify reload |
| `tasks/uninstall.yml` | Route to package or docker uninstall |
| `tasks/facts.yml` | Register headscale_url, headscale_version_installed |
| `templates/config.yaml.j2` | Headscale server configuration |
| `templates/docker-compose.yml.j2` | Docker Compose service definition |
| `templates/acl_policy.json.j2` | ACL policy file |
| `templates/headscale.service.j2` | systemd unit file (for binary installs on non-Debian) |
| `README.md` | Role documentation with examples |

---

## Task 1: Role skeleton and metadata

**Files:**
- Create: `defaults/main.yml`
- Create: `vars/main.yml`
- Create: `meta/main.yml`
- Create: `handlers/main.yml`

- [ ] **Step 1: Create `defaults/main.yml`**

```yaml
---
# Installation mode: "package" or "docker"
headscale_install_mode: "package"

# State: "present", "latest", or "absent"
headscale_state: "present"

# The public URL clients will use to reach this server (REQUIRED)
headscale_server_url: ""

# Headscale version to install
headscale_version: "0.28.0"

# Server bind addresses
headscale_listen_addr: "0.0.0.0:8080"
headscale_metrics_listen_addr: "0.0.0.0:9090"
headscale_grpc_listen_addr: "0.0.0.0:50443"
headscale_grpc_allow_insecure: false

# IP prefixes for the tailnet
headscale_ip_prefix_v4: "100.64.0.0/10"
headscale_ip_prefix_v6: "fd7a:115c:a1e0::/48"
headscale_ip_allocation: "sequential"

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

# Database
headscale_database_type: "sqlite"

# Logging
headscale_log_level: "info"
headscale_log_format: "text"

# Escape hatch: extra config keys merged into config.yaml
headscale_extra_config: {}

# --- User/Key Management ---

headscale_users: []
# Example:
# headscale_users:
#   - name: "range42-admin"
#   - name: "range42-student"

headscale_preauthkeys: []
# Example:
# headscale_preauthkeys:
#   - user: "range42-admin"
#     reusable: true
#     ephemeral: false
#     expiration: "24h"
#     tags: ["tag:admin"]

headscale_register_key_facts: true
headscale_preauthkeys_force: false

# ACL policy (JSON-compatible dict)
headscale_acl_policy: {}

# --- Docker-specific ---

headscale_docker_image: "headscale/headscale"
headscale_docker_tag: "{{ headscale_version }}"
headscale_docker_data_dir: "/opt/headscale/data"
headscale_docker_config_dir: "/opt/headscale/config"
headscale_docker_compose_dir: "/opt/headscale"

# --- Package-specific ---

headscale_config_dir: "/etc/headscale"
headscale_data_dir: "/var/lib/headscale"
headscale_run_dir: "/var/run/headscale"
headscale_user: "headscale"
headscale_group: "headscale"

# Debug output
verbose: false
```

- [ ] **Step 2: Create `vars/main.yml`**

```yaml
---
# Internal constants — not for end-user modification.

headscale_github_base_url: "https://github.com/juanfont/headscale/releases/download"

# Architecture mapping: ansible_architecture → headscale release arch
headscale_arch_map:
  x86_64: "amd64"
  aarch64: "arm64"

# Download URL patterns
headscale_deb_url: "{{ headscale_github_base_url }}/v{{ headscale_version }}/headscale_{{ headscale_version }}_linux_{{ headscale_arch_map[ansible_architecture] }}.deb"
headscale_binary_url: "{{ headscale_github_base_url }}/v{{ headscale_version }}/headscale_{{ headscale_version }}_linux_{{ headscale_arch_map[ansible_architecture] }}"

# OS family detection
headscale_debian_family:
  - "Debian"
  - "Ubuntu"
  - "Pop!_OS"
  - "Linux Mint"

headscale_redhat_family:
  - "CentOS"
  - "RedHat"
  - "Rocky"
  - "AlmaLinux"
  - "Fedora"
  - "Amazon"

# Package/binary paths
headscale_binary_path: "/usr/local/bin/headscale"
headscale_service_name: "headscale"

# Config file paths (resolved at runtime based on install mode)
headscale_effective_config_dir: "{{ headscale_docker_config_dir if headscale_install_mode == 'docker' else headscale_config_dir }}"
headscale_effective_data_dir: "{{ headscale_docker_data_dir if headscale_install_mode == 'docker' else headscale_data_dir }}"

# State file for pre-auth key idempotency
headscale_preauthkeys_state_file: "{{ headscale_effective_data_dir }}/ansible-preauthkeys.json"

# CLI command prefix (direct or via docker exec)
headscale_cli: "{{ 'docker exec headscale headscale' if headscale_install_mode == 'docker' else 'headscale' }}"
```

- [ ] **Step 3: Create `meta/main.yml`**

```yaml
---
galaxy_info:
  author: "Range42"
  description: "Install and configure Headscale — self-hosted Tailscale coordination server"
  license: "GPL-3.0"
  min_ansible_version: "2.12"
  platforms:
    - name: Ubuntu
      versions:
        - focal
        - jammy
        - noble
    - name: Debian
      versions:
        - bullseye
        - bookworm
    - name: EL
      versions:
        - "8"
        - "9"
    - name: Fedora
      versions:
        - "39"
        - "40"
  galaxy_tags:
    - headscale
    - tailscale
    - vpn
    - wireguard
    - networking

dependencies: []
```

- [ ] **Step 4: Create `handlers/main.yml`**

```yaml
---
- name: Restart headscale (package)
  become: true
  ansible.builtin.systemd:
    name: "{{ headscale_service_name }}"
    state: restarted
    daemon_reload: true
  when: headscale_install_mode == "package"

- name: Restart headscale (docker)
  community.docker.docker_compose_v2:
    project_src: "{{ headscale_docker_compose_dir }}"
    state: restarted
  when: headscale_install_mode == "docker"

- name: Reload headscale (package)
  become: true
  ansible.builtin.systemd:
    name: "{{ headscale_service_name }}"
    state: reloaded
  when: headscale_install_mode == "package"

- name: Reload headscale (docker)
  community.docker.docker_compose_v2:
    project_src: "{{ headscale_docker_compose_dir }}"
    state: restarted
  when: headscale_install_mode == "docker"
```

- [ ] **Step 5: Commit**

```bash
git add defaults/main.yml vars/main.yml meta/main.yml handlers/main.yml
git commit -m "feat(headscale): add role skeleton with defaults, vars, meta, handlers"
```

---

## Task 2: Entry point and validation

**Files:**
- Create: `tasks/main.yml`

- [ ] **Step 1: Create `tasks/main.yml`**

```yaml
---
- name: Validate | headscale_state must be valid
  ansible.builtin.fail:
    msg: "'headscale_state' must be 'present', 'latest', or 'absent'. Got: '{{ headscale_state }}'"
  when:
    - headscale_state not in ['present', 'latest', 'absent']

- name: Validate | headscale_install_mode must be valid
  ansible.builtin.fail:
    msg: "'headscale_install_mode' must be 'package' or 'docker'. Got: '{{ headscale_install_mode }}'"
  when:
    - headscale_install_mode not in ['package', 'docker']

- name: Validate | headscale_server_url is required for install
  ansible.builtin.fail:
    msg: "You must set 'headscale_server_url' (e.g. 'https://headscale.example.com')."
  when:
    - headscale_state != 'absent'
    - not headscale_server_url

- name: Validate | headscale_preauthkeys users must exist in headscale_users
  ansible.builtin.fail:
    msg: "Pre-auth key references user '{{ item.user }}' which is not in headscale_users."
  loop: "{{ headscale_preauthkeys }}"
  when:
    - headscale_preauthkeys | length > 0
    - item.user not in (headscale_users | map(attribute='name') | list)

- name: Uninstall Headscale
  ansible.builtin.include_tasks: uninstall.yml
  when: headscale_state == 'absent'

- name: Install and configure Headscale
  when: headscale_state in ['present', 'latest']
  block:
    - name: Install Headscale
      ansible.builtin.include_tasks: install.yml

    - name: Configure Headscale
      ansible.builtin.include_tasks: configure.yml

    - name: Start Headscale
      ansible.builtin.include_tasks: start.yml

    - name: Manage users
      ansible.builtin.include_tasks: users.yml
      when: headscale_users | length > 0

    - name: Manage pre-auth keys
      ansible.builtin.include_tasks: preauthkeys.yml
      when: headscale_preauthkeys | length > 0

    - name: Configure ACL policy
      ansible.builtin.include_tasks: acl.yml
      when: headscale_acl_policy | length > 0

    - name: Register facts
      ansible.builtin.include_tasks: facts.yml
```

- [ ] **Step 2: Commit**

```bash
git add tasks/main.yml
git commit -m "feat(headscale): add main entry point with validation and flow control"
```

---

## Task 3: Package install and uninstall

**Files:**
- Create: `tasks/install.yml`
- Create: `tasks/package/install.yml`
- Create: `tasks/package/uninstall.yml`
- Create: `templates/headscale.service.j2`

- [ ] **Step 1: Create `tasks/install.yml`**

```yaml
---
- name: Install | Package mode
  ansible.builtin.include_tasks: package/install.yml
  when: headscale_install_mode == "package"

- name: Install | Docker mode
  ansible.builtin.include_tasks: docker/install.yml
  when: headscale_install_mode == "docker"
```

- [ ] **Step 2: Create `tasks/package/install.yml`**

```yaml
---
- name: Package | Check if headscale is already installed
  ansible.builtin.command: headscale version
  register: headscale_current_version
  changed_when: false
  failed_when: false

- name: Package | Parse installed version
  ansible.builtin.set_fact:
    headscale_installed_version: "{{ headscale_current_version.stdout | regex_search('v?([0-9]+\\.[0-9]+\\.[0-9]+)', '\\1') | first | default('') }}"
  when: headscale_current_version.rc == 0

- name: Package | Determine if install/upgrade is needed
  ansible.builtin.set_fact:
    headscale_needs_install: >-
      {{ headscale_current_version.rc != 0
         or (headscale_state == 'latest' and (headscale_installed_version | default('')) != headscale_version) }}

- name: Package | Install on Debian family
  when:
    - headscale_needs_install | bool
    - ansible_distribution in headscale_debian_family
  block:
    - name: Package | Download .deb
      ansible.builtin.get_url:
        url: "{{ headscale_deb_url }}"
        dest: "/tmp/headscale_{{ headscale_version }}.deb"
        mode: "0644"

    - name: Package | Install .deb
      become: true
      ansible.builtin.apt:
        deb: "/tmp/headscale_{{ headscale_version }}.deb"
        state: present

    - name: Package | Clean up .deb
      ansible.builtin.file:
        path: "/tmp/headscale_{{ headscale_version }}.deb"
        state: absent

- name: Package | Install on RedHat family (binary)
  when:
    - headscale_needs_install | bool
    - ansible_distribution in headscale_redhat_family or ansible_distribution not in headscale_debian_family
  block:
    - name: Package | Download binary
      ansible.builtin.get_url:
        url: "{{ headscale_binary_url }}"
        dest: "{{ headscale_binary_path }}"
        mode: "0755"
        owner: root
        group: root
      become: true

    - name: Package | Template systemd unit file
      become: true
      ansible.builtin.template:
        src: headscale.service.j2
        dest: /etc/systemd/system/headscale.service
        owner: root
        group: root
        mode: "0644"
      notify: Restart headscale (package)

- name: Package | Create headscale system group
  become: true
  ansible.builtin.group:
    name: "{{ headscale_group }}"
    system: true
    state: present

- name: Package | Create headscale system user
  become: true
  ansible.builtin.user:
    name: "{{ headscale_user }}"
    group: "{{ headscale_group }}"
    system: true
    shell: /usr/sbin/nologin
    home: "{{ headscale_data_dir }}"
    create_home: false

- name: Package | Create directories
  become: true
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: "{{ headscale_user }}"
    group: "{{ headscale_group }}"
    mode: "0750"
  loop:
    - "{{ headscale_config_dir }}"
    - "{{ headscale_data_dir }}"
    - "{{ headscale_run_dir }}"

- name: Package | Current version
  ansible.builtin.debug:
    msg: "Headscale {{ headscale_version }} installed (mode: package)"
  when: verbose
```

- [ ] **Step 3: Create `templates/headscale.service.j2`**

```ini
[Unit]
Description=Headscale - Tailscale coordination server
Documentation=https://github.com/juanfont/headscale
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={{ headscale_user }}
Group={{ headscale_group }}
ExecStart={{ headscale_binary_path }} serve --config {{ headscale_config_dir }}/config.yaml
Restart=on-failure
RestartSec=5
RuntimeDirectory=headscale
RuntimeDirectoryMode=0750

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths={{ headscale_data_dir }} {{ headscale_run_dir }}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 4: Create `tasks/package/uninstall.yml`**

```yaml
---
- name: Package Uninstall | Stop and disable service
  become: true
  ansible.builtin.systemd:
    name: "{{ headscale_service_name }}"
    state: stopped
    enabled: false
  failed_when: false

- name: Package Uninstall | Remove .deb package
  become: true
  ansible.builtin.apt:
    name: headscale
    state: absent
    purge: true
  when: ansible_distribution in headscale_debian_family
  failed_when: false

- name: Package Uninstall | Remove binary
  become: true
  ansible.builtin.file:
    path: "{{ headscale_binary_path }}"
    state: absent
  when: ansible_distribution not in headscale_debian_family

- name: Package Uninstall | Remove systemd unit file
  become: true
  ansible.builtin.file:
    path: /etc/systemd/system/headscale.service
    state: absent
  notify: Restart headscale (package)

- name: Package Uninstall | Reload systemd daemon
  become: true
  ansible.builtin.systemd:
    daemon_reload: true

- name: Package Uninstall | Remove directories
  become: true
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - "{{ headscale_config_dir }}"
    - "{{ headscale_data_dir }}"
    - "{{ headscale_run_dir }}"

- name: Package Uninstall | Remove system user
  become: true
  ansible.builtin.user:
    name: "{{ headscale_user }}"
    state: absent
    remove: true

- name: Package Uninstall | Remove system group
  become: true
  ansible.builtin.group:
    name: "{{ headscale_group }}"
    state: absent
```

- [ ] **Step 5: Commit**

```bash
git add tasks/install.yml tasks/package/ templates/headscale.service.j2
git commit -m "feat(headscale): add package install/uninstall with deb and binary support"
```

---

## Task 4: Docker install and uninstall

**Files:**
- Create: `tasks/docker/install.yml`
- Create: `tasks/docker/uninstall.yml`
- Create: `templates/docker-compose.yml.j2`

- [ ] **Step 1: Create `tasks/docker/install.yml`**

```yaml
---
- name: Docker | Check Docker is available
  ansible.builtin.command: docker --version
  changed_when: false
  register: docker_check
  failed_when: false

- name: Docker | Fail if Docker is not installed
  ansible.builtin.fail:
    msg: "Docker is required for headscale_install_mode='docker' but was not found."
  when: docker_check.rc != 0

- name: Docker | Create directories
  become: true
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0750"
  loop:
    - "{{ headscale_docker_compose_dir }}"
    - "{{ headscale_docker_config_dir }}"
    - "{{ headscale_docker_data_dir }}"

- name: Docker | Pull headscale image
  community.docker.docker_image:
    name: "{{ headscale_docker_image }}"
    tag: "{{ headscale_docker_tag }}"
    source: pull

- name: Docker | Template docker-compose.yml
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ headscale_docker_compose_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: "0640"
  notify: Restart headscale (docker)

- name: Docker | Current image
  ansible.builtin.debug:
    msg: "Headscale {{ headscale_docker_image }}:{{ headscale_docker_tag }} ready (mode: docker)"
  when: verbose
```

- [ ] **Step 2: Create `templates/docker-compose.yml.j2`**

```yaml
# Managed by Ansible — do not edit manually.
services:
  headscale:
    image: {{ headscale_docker_image }}:{{ headscale_docker_tag }}
    container_name: headscale
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /var/run/headscale
    ports:
      - "{{ headscale_listen_addr }}:8080"
      - "{{ headscale_metrics_listen_addr }}:9090"
      - "{{ headscale_grpc_listen_addr }}:50443"
    volumes:
      - {{ headscale_docker_config_dir }}:/etc/headscale:ro
      - {{ headscale_docker_data_dir }}:/var/lib/headscale
    command: serve
    healthcheck:
      test: ["CMD", "headscale", "health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s
```

- [ ] **Step 3: Create `tasks/docker/uninstall.yml`**

```yaml
---
- name: Docker Uninstall | Stop and remove containers
  community.docker.docker_compose_v2:
    project_src: "{{ headscale_docker_compose_dir }}"
    state: absent
    remove_volumes: true
  failed_when: false

- name: Docker Uninstall | Remove compose file
  ansible.builtin.file:
    path: "{{ headscale_docker_compose_dir }}/docker-compose.yml"
    state: absent

- name: Docker Uninstall | Remove directories
  become: true
  ansible.builtin.file:
    path: "{{ item }}"
    state: absent
  loop:
    - "{{ headscale_docker_config_dir }}"
    - "{{ headscale_docker_data_dir }}"
    - "{{ headscale_docker_compose_dir }}"

- name: Docker Uninstall | Remove image
  community.docker.docker_image:
    name: "{{ headscale_docker_image }}"
    tag: "{{ headscale_docker_tag }}"
    state: absent
  failed_when: false
```

- [ ] **Step 4: Commit**

```bash
git add tasks/docker/ templates/docker-compose.yml.j2
git commit -m "feat(headscale): add docker install/uninstall with compose template"
```

---

## Task 5: Configuration template

**Files:**
- Create: `tasks/configure.yml`
- Create: `templates/config.yaml.j2`

- [ ] **Step 1: Create `templates/config.yaml.j2`**

```yaml
# Managed by Ansible — do not edit manually.
---
server_url: {{ headscale_server_url }}
listen_addr: {{ headscale_listen_addr }}
metrics_listen_addr: {{ headscale_metrics_listen_addr }}
grpc_listen_addr: {{ headscale_grpc_listen_addr }}
grpc_allow_insecure: {{ headscale_grpc_allow_insecure | lower }}

noise:
  private_key_path: {{ headscale_effective_data_dir }}/noise_private.key

prefixes:
  v4: {{ headscale_ip_prefix_v4 }}
  v6: {{ headscale_ip_prefix_v6 }}
  allocation: {{ headscale_ip_allocation }}

derp:
  server:
    enabled: false
  urls:
{% for url in headscale_derp_urls %}
    - {{ url }}
{% endfor %}
  paths: []
  auto_update_enabled: {{ headscale_derp_auto_update | lower }}
  update_frequency: 3h

disable_check_updates: false
ephemeral_node_inactivity_timeout: 30m

database:
  type: {{ headscale_database_type }}
  sqlite:
    path: {{ headscale_effective_data_dir }}/db.sqlite
    write_ahead_log: true

log:
  level: {{ headscale_log_level }}
  format: {{ headscale_log_format }}

{% if headscale_acl_policy | length > 0 %}
policy:
  mode: file
  path: {{ headscale_effective_config_dir }}/acl_policy.json
{% endif %}

dns:
  magic_dns: {{ headscale_dns_magic_dns | lower }}
  base_domain: {{ headscale_dns_base_domain }}
  nameservers:
    global:
{% for ns in headscale_dns_nameservers %}
      - {{ ns }}
{% endfor %}
    split: {}
  search_domains: []
  extra_records: []

unix_socket: {{ headscale_run_dir if headscale_install_mode == 'package' else '/var/run/headscale' }}/headscale.sock
unix_socket_permission: "0770"

logtail:
  enabled: false

randomize_client_port: false

{% for key, value in headscale_extra_config.items() %}
{{ key }}: {{ value | to_nice_yaml | indent(0) }}
{% endfor %}
```

- [ ] **Step 2: Create `tasks/configure.yml`**

```yaml
---
- name: Configure | Template config.yaml
  become: true
  ansible.builtin.template:
    src: config.yaml.j2
    dest: "{{ headscale_effective_config_dir }}/config.yaml"
    owner: "{{ headscale_user if headscale_install_mode == 'package' else 'root' }}"
    group: "{{ headscale_group if headscale_install_mode == 'package' else 'root' }}"
    mode: "0640"
  register: headscale_config_result

- name: Configure | Notify restart if config changed (package)
  ansible.builtin.debug:
    msg: "Config changed, restart will be triggered."
  changed_when: headscale_config_result is changed
  notify: Restart headscale (package)
  when:
    - headscale_install_mode == "package"
    - headscale_config_result is changed

- name: Configure | Notify restart if config changed (docker)
  ansible.builtin.debug:
    msg: "Config changed, restart will be triggered."
  changed_when: headscale_config_result is changed
  notify: Restart headscale (docker)
  when:
    - headscale_install_mode == "docker"
    - headscale_config_result is changed
```

- [ ] **Step 3: Commit**

```bash
git add tasks/configure.yml templates/config.yaml.j2
git commit -m "feat(headscale): add config.yaml template and configure task"
```

---

## Task 6: Start service and uninstall router

**Files:**
- Create: `tasks/start.yml`
- Create: `tasks/uninstall.yml`

- [ ] **Step 1: Create `tasks/start.yml`**

```yaml
---
- name: Start | Enable and start systemd service
  become: true
  ansible.builtin.systemd:
    name: "{{ headscale_service_name }}"
    state: started
    enabled: true
    daemon_reload: true
  when: headscale_install_mode == "package"

- name: Start | Docker compose up
  community.docker.docker_compose_v2:
    project_src: "{{ headscale_docker_compose_dir }}"
    state: present
  when: headscale_install_mode == "docker"

- name: Start | Wait for headscale to be ready
  ansible.builtin.command: "{{ headscale_cli }} health"
  register: headscale_health
  retries: 10
  delay: 3
  until: headscale_health.rc == 0
  changed_when: false
```

- [ ] **Step 2: Create `tasks/uninstall.yml`**

```yaml
---
- name: Uninstall | Package mode
  ansible.builtin.include_tasks: package/uninstall.yml
  when: headscale_install_mode == "package"

- name: Uninstall | Docker mode
  ansible.builtin.include_tasks: docker/uninstall.yml
  when: headscale_install_mode == "docker"
```

- [ ] **Step 3: Commit**

```bash
git add tasks/start.yml tasks/uninstall.yml
git commit -m "feat(headscale): add start and uninstall routing tasks"
```

---

## Task 7: User management

**Files:**
- Create: `tasks/users.yml`

- [ ] **Step 1: Create `tasks/users.yml`**

```yaml
---
- name: Users | List existing users
  ansible.builtin.command: "{{ headscale_cli }} users list -o json"
  register: headscale_existing_users_raw
  changed_when: false

- name: Users | Parse existing users
  ansible.builtin.set_fact:
    headscale_existing_user_names: "{{ (headscale_existing_users_raw.stdout | from_json) | map(attribute='name') | list }}"

- name: Users | Show existing users
  ansible.builtin.debug:
    msg: "Existing users: {{ headscale_existing_user_names }}"
  when: verbose

- name: Users | Create missing users
  ansible.builtin.command: "{{ headscale_cli }} users create {{ item.name }} -o json"
  loop: "{{ headscale_users }}"
  when: item.name not in headscale_existing_user_names
  register: headscale_users_created_raw
  changed_when: true

- name: Users | Refresh user list
  ansible.builtin.command: "{{ headscale_cli }} users list -o json"
  register: headscale_users_after_raw
  changed_when: false

- name: Users | Register users fact
  ansible.builtin.set_fact:
    headscale_users_created: "{{ (headscale_users_after_raw.stdout | from_json) | map(attribute='name') | list }}"

- name: Users | Build user name-to-ID mapping
  ansible.builtin.set_fact:
    headscale_user_id_map: "{{ dict((headscale_users_after_raw.stdout | from_json) | map(attribute='name') | zip((headscale_users_after_raw.stdout | from_json) | map(attribute='id'))) }}"
```

- [ ] **Step 2: Commit**

```bash
git add tasks/users.yml
git commit -m "feat(headscale): add idempotent user management"
```

---

## Task 8: Pre-auth key management

**Files:**
- Create: `tasks/preauthkeys.yml`

- [ ] **Step 1: Create `tasks/preauthkeys.yml`**

```yaml
---
- name: PreAuthKeys | Read existing state file
  ansible.builtin.slurp:
    src: "{{ headscale_preauthkeys_state_file }}"
  register: headscale_preauthkeys_state_raw
  failed_when: false

- name: PreAuthKeys | Parse state file
  ansible.builtin.set_fact:
    headscale_preauthkeys_state: "{{ (headscale_preauthkeys_state_raw.content | b64decode | from_json) if headscale_preauthkeys_state_raw is not failed else {} }}"

- name: PreAuthKeys | Generate keys for each entry
  ansible.builtin.include_tasks: _preauthkey_create.yml
  loop: "{{ headscale_preauthkeys }}"
  loop_control:
    loop_var: preauthkey_entry

- name: PreAuthKeys | Write state file
  become: true
  ansible.builtin.copy:
    content: "{{ headscale_preauthkeys_state | to_nice_json }}"
    dest: "{{ headscale_preauthkeys_state_file }}"
    owner: "{{ headscale_user if headscale_install_mode == 'package' else 'root' }}"
    group: "{{ headscale_group if headscale_install_mode == 'package' else 'root' }}"
    mode: "0600"

- name: PreAuthKeys | Register keys fact
  ansible.builtin.set_fact:
    headscale_preauthkeys_generated: "{{ headscale_preauthkeys_state }}"
  when: headscale_register_key_facts
```

- [ ] **Step 2: Create helper task file `tasks/_preauthkey_create.yml`**

This is an internal include looped over each pre-auth key entry.

```yaml
---
- name: "PreAuthKey | Check if key exists for user '{{ preauthkey_entry.user }}'"
  ansible.builtin.set_fact:
    _preauthkey_exists: "{{ preauthkey_entry.user in headscale_preauthkeys_state and not headscale_preauthkeys_force }}"

- name: "PreAuthKey | Skip — key already exists for '{{ preauthkey_entry.user }}'"
  ansible.builtin.debug:
    msg: "Key already exists in state file for user '{{ preauthkey_entry.user }}', skipping."
  when: _preauthkey_exists | bool

- name: "PreAuthKey | Resolve user ID for '{{ preauthkey_entry.user }}'"
  ansible.builtin.set_fact:
    _preauthkey_user_id: "{{ headscale_user_id_map[preauthkey_entry.user] }}"
  when: not (_preauthkey_exists | bool)

- name: "PreAuthKey | Build CLI arguments for '{{ preauthkey_entry.user }}'"
  ansible.builtin.set_fact:
    _preauthkey_args: >-
      --user {{ _preauthkey_user_id }}
      {{ '--reusable' if preauthkey_entry.reusable | default(false) else '' }}
      {{ '--ephemeral' if preauthkey_entry.ephemeral | default(false) else '' }}
      --expiration {{ preauthkey_entry.expiration | default('1h') }}
      {{ '--tags ' + (preauthkey_entry.tags | join(',')) if preauthkey_entry.tags | default([]) | length > 0 else '' }}
  when: not (_preauthkey_exists | bool)

- name: "PreAuthKey | Create key for '{{ preauthkey_entry.user }}'"
  ansible.builtin.command: "{{ headscale_cli }} preauthkeys create {{ _preauthkey_args | trim }} -o json"
  register: _preauthkey_result
  changed_when: true
  no_log: true
  when: not (_preauthkey_exists | bool)

- name: "PreAuthKey | Store key in state for '{{ preauthkey_entry.user }}'"
  ansible.builtin.set_fact:
    headscale_preauthkeys_state: "{{ headscale_preauthkeys_state | combine({preauthkey_entry.user: (_preauthkey_result.stdout | from_json).key}) }}"
  no_log: true
  when: not (_preauthkey_exists | bool)
```

- [ ] **Step 3: Commit**

```bash
git add tasks/preauthkeys.yml tasks/_preauthkey_create.yml
git commit -m "feat(headscale): add pre-auth key management with state file idempotency"
```

---

## Task 9: ACL policy and facts

**Files:**
- Create: `tasks/acl.yml`
- Create: `templates/acl_policy.json.j2`
- Create: `tasks/facts.yml`

- [ ] **Step 1: Create `templates/acl_policy.json.j2`**

```json
{{ headscale_acl_policy | to_nice_json }}
```

- [ ] **Step 2: Create `tasks/acl.yml`**

```yaml
---
- name: ACL | Template policy file
  become: true
  ansible.builtin.template:
    src: acl_policy.json.j2
    dest: "{{ headscale_effective_config_dir }}/acl_policy.json"
    owner: "{{ headscale_user if headscale_install_mode == 'package' else 'root' }}"
    group: "{{ headscale_group if headscale_install_mode == 'package' else 'root' }}"
    mode: "0640"
  register: headscale_acl_result

- name: ACL | Notify reload if policy changed (package)
  ansible.builtin.debug:
    msg: "ACL policy changed, reload triggered."
  changed_when: headscale_acl_result is changed
  notify: Reload headscale (package)
  when:
    - headscale_install_mode == "package"
    - headscale_acl_result is changed

- name: ACL | Notify reload if policy changed (docker)
  ansible.builtin.debug:
    msg: "ACL policy changed, reload triggered."
  changed_when: headscale_acl_result is changed
  notify: Reload headscale (docker)
  when:
    - headscale_install_mode == "docker"
    - headscale_acl_result is changed
```

- [ ] **Step 3: Create `tasks/facts.yml`**

```yaml
---
- name: Facts | Get headscale version
  ansible.builtin.command: "{{ headscale_cli }} version"
  register: headscale_version_output
  changed_when: false

- name: Facts | Register output facts
  ansible.builtin.set_fact:
    headscale_url: "{{ headscale_server_url }}"
    headscale_version_installed: "{{ headscale_version_output.stdout | regex_search('v?([0-9]+\\.[0-9]+\\.[0-9]+)', '\\1') | first | default(headscale_version) }}"

- name: Facts | Summary
  ansible.builtin.debug:
    msg: >
      Headscale {{ headscale_version_installed }} running at {{ headscale_url }}
      (mode: {{ headscale_install_mode }})
      Users: {{ headscale_users_created | default([]) | join(', ') }}
```

- [ ] **Step 4: Commit**

```bash
git add tasks/acl.yml tasks/facts.yml templates/acl_policy.json.j2
git commit -m "feat(headscale): add ACL policy management and output facts"
```

---

## Task 10: README documentation

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create `README.md`**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(headscale): add role README with examples and variable reference"
```

---

## Task 11: Final review and integration commit

- [ ] **Step 1: Verify the full role directory structure**

```bash
find range42-catalog/02_ansible_layer/admin/roles/software.install.headscale/ -type f | sort
```

Expected output:
```
defaults/main.yml
handlers/main.yml
meta/main.yml
README.md
tasks/_preauthkey_create.yml
tasks/acl.yml
tasks/configure.yml
tasks/docker/install.yml
tasks/docker/uninstall.yml
tasks/facts.yml
tasks/install.yml
tasks/main.yml
tasks/package/install.yml
tasks/package/uninstall.yml
tasks/preauthkeys.yml
tasks/start.yml
tasks/uninstall.yml
tasks/users.yml
templates/acl_policy.json.j2
templates/config.yaml.j2
templates/docker-compose.yml.j2
templates/headscale.service.j2
vars/main.yml
```

- [ ] **Step 2: Dry-run syntax check**

```bash
cd range42-catalog
ansible-playbook --syntax-check -e "headscale_server_url=http://test:8080" -i localhost, -c local /dev/stdin <<'EOF'
- hosts: localhost
  roles:
    - role: 02_ansible_layer/admin/roles/software.install.headscale
      vars:
        headscale_server_url: "http://test:8080"
        headscale_up_skip: true
EOF
```

Expected: `playbook: /dev/stdin` with no syntax errors.

- [ ] **Step 3: Fix any issues found, then final commit**

```bash
git add -A range42-catalog/02_ansible_layer/admin/roles/software.install.headscale/
git commit -m "feat(headscale): complete Ansible role for Headscale v0.28 server"
```
