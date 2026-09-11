# Cloud-init boot wait failure diagnostics

This isolated change starts from catalog
`4fcf913574c7928517c0357bf3fbd99b190b135c`. It addresses the missing diagnostic
seen in shared attempt `0531023567404da6`: SSH readiness passed, but the
`boot-finished` wait failed after 500 seconds. The reported package workers
are acceptance evidence supplied by the deployment team; this helper does
not inspect or infer package commands.

`tasks/wait/cloudinit/is_boot_finished.yml` keeps the existing 10-second delay
and 500-second limit. On failure, its rescue runs the guest-side
`files/cloudinit_boot_diagnostic.py` while the attempt's SSH connection and
credentials still exist. The helper invokes `cloud-init status --format=json`
without `--wait`. It has a five-second collection deadline, a 64 KiB stdout
limit, and bounded child cleanup. The Ansible diagnostic task also has a
15-second action timeout. These are diagnostic bounds, not an extension of
the boot readiness wait.

The helper emits only an allowlisted status, top-level stage, error counts
and availability. Raw JSON, error strings, datasource details, stderr, logs,
user data, command lines and environment values are never returned to
Ansible. The collection task also uses `no_log`; public fields are validated
again before use in the final task name/message. Missing data is represented
as unknown, never inferred from completed stage records or reported as zero.

Valid status JSON from exit codes 0, 1 and 2 can provide a diagnosis. Missing
CLI, incompatible output, malformed/oversized data, command timeout or lost
SSH produce `diagnostic=unavailable`. A fresh invocation clears previous
candidate facts. The final task always fails with
`CLOUD_INIT_BOOT_WAIT_FAILED`; neither an unavailable diagnostic nor a newly
completed cloud-init status converts the original wait failure to success.

Example public message:

```text
CLOUD_INIT_BOOT_WAIT_FAILED: boot-finished wait failed (configured limit 500s).
diagnostic=available; status=running; stage=modules-final; errors=0;
recoverable_errors=0. Guest initialization may still be running.
Inspect the guest before retrying.
```

The existing backend saves failed task names/results and drains the event
watcher before terminal credential/output cleanup, including recovered
attempts. The UI activity bridge prefers `task_name`, so the final task name
also contains the sanitized status/stage. No backend, UI or cleanup-policy
change is required. A release must pin this catalog revision and regenerate
the installed dependency profile; old bundle resolutions must be resolved
against that matching profile. Nothing in this worktree activates a release.

Limits: this is failure diagnostics, not package repair or a new readiness
policy. A pre-existing `boot-finished` file still follows the original success
path. Status availability does not establish an exact stuck module or an apt
network/GPG cause. The helper needs Python 3, already required by the existing
Ansible `wait_for` execution. SSH loss may prevent any guest observation; the
fixed unavailable message still preserves the failure.

Run the focused checks from the catalog root:

```sh
pytest -q 02_ansible_layer/admin/roles/ansible.utils/tests/test_cloudinit_diagnostic.py 02_ansible_layer/admin/roles/ansible.utils/tests/test_cloudinit_wait_ansible.py
```

Tests use a private cloud-init executable and local Ansible transports; they
never read host cloud-init data or contact guests. They cover successful,
failed and degraded status, absent stage, malformed and oversized data,
missing CLI, a timed-out process, secret canaries, failed-wait propagation,
SSH loss, stale facts and the unchanged successful wait path.

Checkpoint validation: all 20 focused tests passed (15 helper cases and five
real local Ansible cases) in 11.67s; scoped Ruff and `git diff --check` passed.
Log: `/tmp/r42-cloudinit-diagnostic-final.log`. The existing pytest asyncio
default-loop configuration warning remains. No full catalog suite or live
guest acceptance was run for this isolated change.

Primary contracts: [cloud-init CLI status](https://docs.cloud-init.io/en/latest/reference/cli.html#status)
documents JSON and exit status 2 for recoverable errors;
[reported status](https://docs.cloud-init.io/en/24.1/howto/status.html)
defines the status/stage output;
[exported errors](https://docs.cloud-init.io/en/24.1/explanation/exported_errors.html)
describes completed-stage error records, which are not an active-stage signal.
