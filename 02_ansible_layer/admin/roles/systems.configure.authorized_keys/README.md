# systems.configure.authorized_keys

Add or remove a public key in `~<TARGET_USER>/.ssh/authorized_keys` (SSH-in). Uses
`ansible.posix.authorized_key`. Single-responsibility, composable, idempotent.

Invoked via the thin bundle `range42-playbooks/bundles/core/systems.configure.authorized_keys/`.

## Variables

| Var | Req | Default | Meaning |
|---|---|---|---|
| `TARGET_USER` | yes | - | user whose `authorized_keys` is managed |
| `AUTHORIZED_KEY` | yes | - | the public key string |
| `AUTHORIZED_KEY_STATE` | no | `present` | `present` / `absent` |
| `AUTHORIZED_KEY_EXCLUSIVE` | no | `false` | remove all other keys if `true` |
