# systems.configure.sudo

Grant or revoke sudo for a user via a `/etc/sudoers.d/90-range42-<user>` drop-in, validated
with `visudo -cf` before it lands (a malformed file is rejected, never written -> cannot break
sudo on the host). Single-responsibility, composable, idempotent.

Invoked via the thin bundle `range42-playbooks/bundles/core/systems.configure.sudo/`.

## Variables

| Var | Req | Default | Meaning |
|---|---|---|---|
| `TARGET_USER` | yes | - | user to grant/revoke sudo |
| `SUDO_STATE` | no | `present` | `present` / `absent` |
| `SUDO_NOPASSWD` | no | `false` | `true` -> `NOPASSWD:ALL` |
