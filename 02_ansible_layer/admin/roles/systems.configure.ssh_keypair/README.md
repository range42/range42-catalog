# systems.configure.ssh_keypair

Deploy an SSH keypair (private + optional public) into `~<TARGET_USER>/.ssh/`, so the user
can SSH out. Single-responsibility, composable, idempotent.

Invoked via the thin bundle `range42-playbooks/bundles/generic/systems.configure.ssh_keypair/`.

## Variables

| Var | Req | Default | Meaning |
|---|---|---|---|
| `TARGET_USER` | yes | - | user whose `~/.ssh` receives the keypair |
| `SSH_KEYPAIR_PRIVATE_SRC` | yes | - | path on the controller to the private key |
| `SSH_KEYPAIR_PUBLIC_SRC` | no | `""` | path on the controller to the public key |
| `SSH_KEYPAIR_NAME` | no | `id_ed25519` | destination filename in `~/.ssh/` |
