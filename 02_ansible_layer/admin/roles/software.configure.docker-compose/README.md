# Deploy an existing Compose project

This role copies a controller-side project to an Ubuntu host and runs its
existing Compose configuration. It installs rsync, starts the project, and
reports the container named by `LABEL_PROJET_NAME`.

The caller supplies `LOCAL__PROJECT_DIR`, `REMOTE_PROJECT_DIR`, `OPERATOR_USER`,
`LABEL_PROJECT_TYPE`, `LABEL_PROJET_NAME`, `SEND_POC_DIR` and
`CLEAN_UP_DEPLOY_DIR`. `FORCE_RECREATE` defaults to `"NO"`.

## SSH transport

Synchronization runs on the controller through the target's configured SSH
arguments, including private configuration, proxy routing and host-key files.
The role leaves host verification enabled and retains the configured OpenSSH
policy. Callers requiring strict trust must select a strict SSH configuration
and known-host pins; synchronization does not enroll keys.

`synchronize` starts on the controller itself. Explicit delegation to localhost
would hide the target SSH connection options from its action plugin. The role
also leaves remote-shell construction to that plugin, rather than replacing
its private key, port and SSH arguments with `-e ssh`.

## Environment files

By default the source `.env` is delivered and updated, as with other project
files. To keep a separately managed destination `.env`, set:

```yaml
DOCKER_COMPOSE_PRESERVE_REMOTE_ENV: true
CLEAN_UP_DEPLOY_DIR: "NO"
```

This excludes only the project-root `.env` from synchronization, in both
`SEND_POC_DIR` modes. It preserves that file's existing bytes and permissions;
it does not create the file if absent. `.env.example` and nested environment
files still follow the normal copy behavior. Stage the protected destination
file before starting Compose. The option does not override an explicitly
requested deployment-directory cleanup.

The default remains `false`, so callers intentionally shipping or updating
their environment files keep the existing behavior. The Gitea bundle's catalog
seed can therefore be used unchanged; a deployment managing its remote secrets
separately must explicitly opt in.

## Validation

`tests/test_compose_sync.py` runs the actual sync tasks with disposable local
files, real rsync and loopback SSH/proxy fixtures. It covers environment-file
retention and delivery, both proof-of-concept modes, quoted private paths,
SSH wrappers and unknown/changed host-key refusal. The SSH fixture ends after
authenticated rsync execution; it does not deploy containers or contact live
hosts. Tests require pytest, PyYAML, cryptography, Paramiko, Ansible,
`ansible.posix`, OpenSSH and rsync.

