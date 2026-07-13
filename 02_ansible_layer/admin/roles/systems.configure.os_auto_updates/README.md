# systems.configure.os_auto_updates

Disable (default) or enable the OS background auto-updater so it never holds the package lock
during provisioning. On fresh VMs the auto-updater starts right after boot and can grab
`/var/lib/dpkg/lock-frontend` (apt) or the rpm/dnf lock, making a following package task fail with
`Could not get lock ... held by process ... (unattended-upgr)`. Lab VMs are ephemeral with a
controlled package state, so disabling the auto-updater is both the fix and the desired behaviour.

Run it EARLY in a play (before any package task). Stopping the units also releases a lock that is
already held. Single-responsibility, composable, idempotent.

Invoked via the thin bundle `range42-playbooks/bundles/core/systems.configure.os_auto_updates/`.

## Structure

OS-branched, one task file per distribution (dispatched from `tasks/main.yml` on
`ansible_facts['distribution']`) :

```
tasks/
  main.yml                        assert + include per distribution
  ubuntu/unattended_updates.yml   apt-daily timers + unattended-upgrades + 20auto-upgrades
  debian/unattended_updates.yml   same apt mechanism as Ubuntu
  fedora/unattended_updates.yml   dnf-automatic timers + PackageKit + automatic.conf
```

## Test status

| OS | Status |
|---|---|
| Ubuntu | tested |
| Debian | **NOT yet tested** (no test environment ; apt mechanism mirrors Ubuntu) |
| Fedora | **NOT yet tested** (no test environment ; dnf mechanism) |

## What it does

- `disabled` (apt) : stop + disable + mask the apt-daily **timers** (no future scheduled runs) ;
  **wait** for the transient lock holders (`apt-daily.service` = download, `apt-daily-upgrade.service`
  = install) to go inactive so the dpkg lock is free - they are never killed (killing one
  mid-transaction corrupts dpkg). `unattended-upgrades.service` is deliberately NOT waited on : it
  is a long-running `--wait-for-signal` daemon that is always active during uptime (it only upgrades
  at shutdown), so it is only masked (never stopped - stopping it would trigger the shutdown upgrade).
  Then disable + mask the services ; write `/etc/apt/apt.conf.d/20auto-upgrades` off.
- `disabled` (dnf, untested) : stop + mask the dnf-automatic timers + PackageKit ;
  `apply_updates = no` in `/etc/dnf/automatic.conf`.
- `enabled` : unmask + enable + start the timers, periodic config back on.

The updater is only prevented from starting NEW runs ; a run already in progress is left to
finish (never force-killed), which is why no `dpkg --configure -a` repair is needed. Missing
units / config files are tolerated (minimal images).

## Variables

| Var | Req | Default | Meaning |
|---|---|---|---|
| `OS_AUTO_UPDATES_STATE` | no | `disabled` | `disabled` / `enabled` |
