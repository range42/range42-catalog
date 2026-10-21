# Table of Contents

- [Repository Content](#repository-content)
- [How range42 consumes the catalog](#how-range42-consumes-the-catalog)
- [Contributing](#contributing)
- [License](#license)

---

# Repository Content

This repository is the **range42 catalog** — a collection of reusable infrastructure elements (Ansible roles, Docker Compose stacks, gamification content) consumed by the bundles and scenarios of [range42-playbooks](https://github.com/range42/range42-playbooks), and through them by the backend API, the [range42-deployer-ui](https://github.com/range42/range42-deployer-ui) and the `range42-context` CLI.

Elements include Ansible roles, Dockerfiles and Docker Compose definitions that configure the admin services of a range and the misconfigured or vulnerable environments of the exercises. The word bundle belongs to range42-playbooks, for the playbooks that wrap these elements. `manifest.json` at the root describes the layers and their categories for the tooling.

The catalog is structured in numbered layers to separate concerns:

## Layer 02 — Ansible

Path: `02_ansible_layer/`

Ansible roles that act directly on the system to configure environments.

- **`admin/roles/`** — roles targeting admin VMs: package warm-up (basic packages, dotfiles, local bin), Docker Compose setup, firewall configuration, Tailscale / Headscale installation, the Wazuh server stack (indexer, manager, dashboard, filebeat) and the Wazuh agent, NTP, OS updates, symlink farms, Node.js app systemd services, user and access management (users, authorized keys, ssh keypairs, sudo), the Gitea OAuth2 wiring of Mattermost, Nextcloud and Rocket.Chat, the Kunai official workshop toolchain, and system health checks.
- **`trainee/roles/`** — roles targeting trainee VMs: `blue_env`, `red_env`, and `malware_env` environment bootstraps.
- **`_ctf/cve/`** — CVE scenario roles, classified by technology: `network/`, `system/`, `web/`.
- **`_ctf/malware/`** — malware scenario roles: `backdoor/`, `keylogger/`, `rootkit/`.
- **`_ctf/misconfiguration/`** — misconfiguration scenario roles, classified by technology: `network/`, `system/`, `web/`.

## Layer 03 — Containers

Path: `03_container_layer/`

Container-based deployments for vulnerable or misconfigured services.

- **`docker/_ctf/cve/`** — Docker / Docker Compose stacks for CVE scenarios.
- **`docker/_ctf/malware/`** — Docker / Docker Compose stacks for malware scenarios.
- **`docker/_ctf/misconfiguration/`** — Docker / Docker Compose stacks for misconfiguration scenarios.
- **`docker/_ctf/hello/`** — Hello-world stack used for smoke-testing deployments.
- **`docker/admin/`** — Docker Compose stacks of the admin tier: Gitea, Gitea registry, Mattermost, MISP standalone, Nextcloud, Rocket.Chat. Each carries a `catalog_try.yml` contract (mode, ports, endpoint, timeout) read by `range42-context catalog-try`.
- **`lxc/`** — LXC container configuration placeholders.

## Layer 04 — Gamification

Path: `04_gamification_layer/`

Interface templates and challenge frameworks that gamify the deployed scenarios.

- **`web/frameworks/`** — challenge web frameworks (HTML, PHP, Vue) providing themed front-ends (e.g. fake hospital, fake bank) on top of the deployed vulnerabilities.
- **`web/shared/`** — shared assets: CSS, JavaScript, i18n strings, and reusable skins.
- **`web/tools/`** — tooling scripts for the web layer.
- **`crypto/notes/`** — notes and resources for crypto challenges.
- **`network/notes/`** — notes and resources for network challenges.
- **`files/notes/`** — notes and resources for file-based challenges.

---

# How range42 consumes the catalog

- The **bundles** of range42-playbooks wrap the elements: the `generic/*` and `admin/software.install.*` bundles import the roles of layer 02 (this repository sits on the Ansible roles path of the deployer-cli), and the `admin/software.install.*` and `ctf/*` bundles deploy the Docker Compose stacks of layer 03 on the VMs of a scenario.
- `range42-context catalog-try <path>` deploys one element of layer 03 on a disposable VM and smoke-checks it against its `catalog_try.yml` contract (a bound port for a service, an exit signature for a oneshot) ; `catalog-try-list` and `catalog-try-list-admin` list the candidates.
- The scenarios of range42-playbooks compose the bundles ; the range42 wizard clones this repository on the deployer-cli next to them.

---

**Note:** The deep tree structure is still evolving and may change as the project grows.

## Contributing

This is a collaborative initiative, developed for applied security training, community integration, and internal capability building.
We use centralized community health files in Range42 community health.

## License

- GPL-3.0 license
