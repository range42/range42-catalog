# Table of Contents

- [Project Overview](#Project-Overview)
- [Repository Content](#Repository-Content)
- [Contributing](#Contributing)
- [License](#License)

---

# Project Overview

**RANGE42** is a modular cyber range platform designed for real-world readiness.
We build, deploy, and document offensive, defensive, and hybrid cyber training environments using reproducible, infrastructure-as-code methodologies.

## What we build

- Proxmox-based cyber ranges with dynamic catalog 
- Ansible roles for automated deployments (Wazuh, Kong, Docker, etc.)
- Private APIs for range orchestration and telemetry
- Developer and testing toolkits and JSON transformers for automation pipelines
- ...

## Repository Overview

- **RANGE42 deployer UI** : A web interface to visually design infrastructure schemas and trigger deployments.
- **RANGE42 deployer backend API** : Orchestrates deployments by executing playbooks and bundles from the catalog.
- **RANGE42 catalog** : A collection of Ansible roles and Docker/Docker Compose stacks, forming deployable bundles.
- **RANGE42 playbooks** : Centralized playbooks that can be invoked by the backend or CLI.
- **RANGE42 proxmox role** : An Ansible role for controlling Proxmox nodes via the Proxmox API.
- **RANGE42 devkit** : Helper scripts for testing, debugging, and development workflows.
- **RANGE42 kong API gateway** : A network service in front of the backend API, handling authentication, ACLs, and access control policies.
- **RANGE42 swagger API spec** : OpenAPI/Swagger JSON definition of the backend API.

### Putting it all together

These repositories provide a modular and extensible platform to design, manage and deploy infrastructures automaticallyeither from the UI (coming soon) or from the CLI through the playbooks repository.

---

# Repository Content

This repository contains the deployment cataloga collection of reusable infrastructure bundles.
Bundles often include Ansible roles, Dockerfiles and/or Docker Compose definitions designed to be orchestrated by the backend API or executed directly via CLI. 

The catalog is currently composed of three parts:

- Ansible roles : act directly on the system to configure misconfigured or vulnerable environments.
- Docker / Docker compose definitions : setup vulnerable or misconfigured services based on containerized environments.
- Interface templates : root directory storing themed templates (e.g. fake hospital, fake bank) designed to gamify the deployed misconfigurations and vulnerabilities.

Currently, the repository tree is organized to classify misconfigurations and CVEs by technology type.

**⚠️ This deep tree structure still volatile and may evolve as the project grows.**

## Contributing

This is a collaborative initiative, developed for applied security training, community integration, and internal capability building.
We use centralized community health files in Range42 community health.

## License

- GPL-3.0 license


