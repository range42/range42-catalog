# software.install.rocketchat

Deploys the **Rocket.Chat** docker-compose stack onto a target box.

The stack itself (Rocket.Chat + MongoDB replica set + token provisioner) lives in
the catalog at [`03_container_layer/docker/admin/rocketchat/`](../../../../03_container_layer/docker/admin/rocketchat/).
This role rsyncs that directory onto the box and brings it up, delegating the
deploy + `docker compose up` to the shared
[`software.configure.docker-compose`](../software.configure.docker-compose/) role.

## Requirements

Docker engine + compose plugin must already be installed on the target. Wire
`software.install.warmup.basic_packages` with `INSTALL_PACKAGES_DOCKER: "YES"`
and `INSTALL_PACKAGES_DOCKER_COMPOSE: "YES"` before this role (the
`admin-rocketchat` box template does this).

`RANGE42_INVENTORY` must be exported on the controller (done by `range42-context`)
so the stack source resolves.

## Role variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ROCKETCHAT_LOCAL_PROJECT_DIR` | `{{ lookup('env', 'RANGE42_INVENTORY') }}/03_container_layer/docker/admin/rocketchat` | Controller-side stack source |
| `ROCKETCHAT_REMOTE_PROJECT_DIR` | `/opt/range42/rocketchat` | Where the stack is staged + run on the box |
| `ROCKETCHAT_OPERATOR_USER` | `{{ default_admin_vm_ci_user }}` | Owner of staged files (scenario cloud-init admin user) |
| `ROCKETCHAT_CONTAINER_NAME` | `rocketchat` | Main container polled after `up` |
| `ROCKETCHAT_LABEL_PROJECT_TYPE` | `admin` | Label only |

## Notes

The compose stack ships sane defaults (admin creds, `ROOT_URL`, `HTTP_PORT=3000`)
via `.env.example`; override by editing the stack's `.env` before deploy. The web
UI listens on port 3000 — open it on the box firewall (the `admin-rocketchat` box
template does).
