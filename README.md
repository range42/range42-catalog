# Table of Contents

- [Repository Content](#Repository-Content)
- [Contributing](#Contributing)
- [License](#License)

---

# Repository Content

This repository is the **range42 catalog** — a collection of reusable infrastructure bundles that can be orchestrated by the backend API or executed directly via the [range42-deployer-ui](https://github.com/range42/range42-deployer-ui) or CLI through the playbooks repository.

Bundles include Ansible roles, Dockerfiles, and Docker Compose definitions designed to configure misconfigured or vulnerable environments for cyber training scenarios.

The catalog is structured in numbered layers to separate concerns:

## Layer 02 — Ansible

Path: `02_ansible_layer/`

Ansible roles that act directly on the system to configure environments.

- **`admin/roles/`** — roles targeting admin VMs: package warm-up, Docker Compose setup, firewall configuration, Tailscale / Headscale installation, Wazuh agent, NTP, symlink farms, Node.js app systemd services, user management, and system health checks.
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

**Note:** The deep tree structure is still evolving and may change as the project grows.

## Contributing

This is a collaborative initiative, developed for applied security training, community integration, and internal capability building.
We use centralized community health files in Range42 community health.

## License

- GPL-3.0 license
