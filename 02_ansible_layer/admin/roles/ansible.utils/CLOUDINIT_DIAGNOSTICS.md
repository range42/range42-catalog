# Cloud-init boot wait failure diagnostics

This extension starts from catalog
`0a9448d4f7daf8e9ba27e5c916237ffbe6ccf6f9`, which introduced the safe status
summary. Shared attempt `505eb94ae7e14839` confirmed that summary works: the
second guest reached package configuration but exceeded the existing boot
wait. A later process probe lost its SSH channel after terminal cleanup.
These observations do not establish the cause of the timeout.

`tasks/wait/cloudinit/is_boot_finished.yml` keeps the existing 10-second delay
and 500-second limit. On failure, its rescue runs the guest-side
`files/cloudinit_boot_diagnostic.py` while the attempt's SSH connection and
credentials still exist. The helper first invokes
`cloud-init status --format=json` without `--wait`, preserving its full
five-second collection budget and 64 KiB stdout limit. It samples package
processes only if time remains within that same deadline. Existing bounded
child cleanup can take another second; the Ansible action retains its
15-second timeout. These are diagnostic bounds, not additional boot wait.

The helper returns only allowlisted status/stage, error counts and
availability, plus these package observations:

- `package_phase`: `apt`, `dpkg`, `initramfs`, `grub`, `none` or `unknown`.
- `package_state`: `running`, `sleeping`, `blocked`, `stopped`, `zombie`,
  `mixed`, `none` or `unknown`.
- `package_cpu_activity`: `observed`, `not_observed` or `unavailable`.
- `package_sample_ms`: the bounded integer observation interval, or null.

Package collection reads only Linux `/proc/<pid>/stat`, twice approximately
100 ms apart. Fixed command-name classifications account for Linux's
15-byte visible `comm` limit. Known package processes must descend from
exactly one identifiable cloud-init worker; their children contribute CPU
counters without exposing their names. Unrelated package processes are
excluded. A more specific observed phase takes precedence (`grub`, then
`initramfs`, `dpkg`, `apt`); it is a process classification, not a cloud-init
module or exact apt operation.

The helper bounds enumeration to 4096 directory entries, each stat read to
4096 bytes, and ancestry to 64 processes. Missing, malformed or inaccessible
records, ambiguous ancestry, changed membership, PID/start-time changes,
changed parents, regressing counters or an exhausted deadline make package
fields unavailable. Valid cloud-init status remains available independently.
There is no persistent sampling service or progress history. CPU movement
is an observation only; no movement in this short interval does not prove a
stall, and movement does not prove successful progress or health. Process
names can be changed by guest processes and are not an integrity guarantee.

Raw JSON, error strings, datasource details, stderr, logs, package names,
user data, command lines and environment values are never returned to
Ansible. The helper does not read argv, environment or package/log contents.
The collection task also uses `no_log`; public fields are validated again
before use in the final task name/message. Unknown data is never inferred
from completed stage records or reported as zero.

Valid status JSON from exit codes 0, 1 and 2 is accepted. Missing CLI,
incompatible output, malformed/oversized data, command timeout or lost SSH
produce an unavailable status. A fresh invocation clears all candidate
facts. The final task always fails with `CLOUD_INIT_BOOT_WAIT_FAILED`;
neither unavailable diagnostics nor newly completed cloud-init status
converts the original wait failure to success.

The existing backend saves failed task names/results and drains its event
watcher before terminal cleanup. The UI activity bridge uses `task_name`,
which now includes the sanitized status/stage and package phase/CPU activity.
No backend, UI, upgrade-policy or cleanup-policy change is required. A
release must pin this catalog revision and regenerate its installed
dependency profile; bundle resolutions must match that profile. This
worktree does not activate a release.

Limits: the unchanged success path still accepts an existing `boot-finished`
file. Diagnostics cannot repair packages or establish a network/GPG cause.
Python 3 and working SSH remain prerequisites; lost SSH preserves the
original failure with unavailable observations. Live acceptance of this
extension remains outstanding.

Run the focused checks from the catalog root:

```sh
python3 -m pytest -q 02_ansible_layer/admin/roles/ansible.utils/tests/test_cloudinit_diagnostic.py 02_ansible_layer/admin/roles/ansible.utils/tests/test_cloudinit_package_progress.py 02_ansible_layer/admin/roles/ansible.utils/tests/test_cloudinit_wait_ansible.py
```

Tests use private cloud-init executables, synthetic proc records and local
Ansible transports; they never read host cloud-init data or contact guests.
They cover status availability, error counts, redaction canaries, byte/time
bounds, package configuration, truncated names, child CPU changes, stale or
ambiguous process identity, enumeration limits, exhausted remaining budget,
malformed public fields, lost SSH, stale facts and failure propagation.

Primary contracts: [cloud-init CLI status](https://docs.cloud-init.io/en/latest/reference/cli.html#status)
documents JSON and exit status 2 for recoverable errors;
[reported status](https://docs.cloud-init.io/en/24.1/howto/status.html)
defines status/stage output;
[exported errors](https://docs.cloud-init.io/en/24.1/explanation/exported_errors.html)
describes completed-stage records, which are not an active-stage signal.

Isolated checkpoint: worktree
`/tmp/r42-cloudinit-package-diagnostics-next-wave`, branch
`fix/cloudinit-package-progress-20260911`. All 41 focused tests passed in
17.15 seconds (15 status, 19 package, seven real local Ansible cases), after
red regressions for the new behavior. Scoped Ruff and `git diff --check`
passed. Log: `/tmp/r42-cloudinit-package-final.log`. The existing pytest
asyncio default-loop configuration warning remains. No broad suite or live
checks were run. Remaining work is independent source review and, only in a
subsequently authorized matching release, live acceptance of the new fields.

The [Linux proc documentation](https://www.kernel.org/doc/html/v6.6/filesystems/proc.html)
defines the `stat` parent PID, user/system CPU counters and process start-time
fields used to scope and compare these observations.
