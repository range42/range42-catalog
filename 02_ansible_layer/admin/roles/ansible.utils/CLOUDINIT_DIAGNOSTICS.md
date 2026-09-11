# Cloud-init diagnostics as Ansible tasks

`tasks/wait/cloudinit/is_boot_finished.yml` retains the existing 10-second delay
and 500-second `boot-finished` wait. A failed wait includes `diagnostic.yml`,
prints an ordinary structured `ansible.builtin.debug` report, then fails with
`CLOUD_INIT_BOOT_WAIT_FAILED`. The final task name retains sanitized status/stage
for the existing backend/UI event bridge. Diagnostics never turn a failed boot
wait into success, including when cloud-init finishes during observation.

The custom Python collector and its Python unit fixtures have been removed.
Parsing, validation, classification, reporting and failure handling now live in
readable YAML tasks using standard Ansible modules and filters. The only shell
pipelines run a native command under `timeout` and cap its output with `head`;
they contain no JSON parser, ancestry traversal or classification program.

## Status report

`cloud-init status --format=json` runs without `--wait`, under a five-second
native deadline plus a one-second forced-stop grace. Its process group is
bounded by GNU `timeout`; stdout is capped at 65,537 bytes, and responses above
65,536 bytes are refused. The Ansible action also has an eight-second timeout.
Exit codes 0, 1 and 2 can carry valid status JSON. Missing commands, malformed or
oversized output, invalid field types, timeout and unreachable transports result
in unavailable status.

The collection, parsing and validation tasks use `no_log`. Only allowlisted
status/stage values and bounded error counts reach the report. Error text,
datasource details, stderr, user data and arbitrary JSON fields are excluded.
Missing counts remain unknown; completed module records do not establish an
active stage. A new invocation resets prior candidates and observations.

## Package observation

When valid status identifies `modules-final`, `package_observation.yml` inspects
one executing `cloud-final.service` invocation on Linux with systemd/cgroup v2:

1. Require unit state `activating` (the executing oneshot case) or `active`, a
   nonzero MainPID, InvocationID and the standard
   `/system.slice/cloud-final.service` cgroup.
2. Refuse child cgroups: direct `cgroup.procs` membership cannot prove their scope.
3. Read at most 16 KiB/1,024 unique PIDs and require the main PID in that list.
4. Use `ps` for only PID, program name (`comm`), state and cgroup fields. Require
   every listed process, with no extra/missing/duplicate rows, in the exact unit
   cgroup, and the main process program must be `cloud-init`. This does not read
   command-line arguments or environment variables.
5. Recheck membership, invocation/active state and child-cgroup absence before
   publishing any observation.

Each native unit/membership/process command has a three-second deadline plus
one-second kill grace and a six-second Ansible action timeout. Process output is
capped at 65,536 bytes. There are seven bounded commands on this path; diagnostics
are additional observations after the unchanged failed boot wait, not a new
package wait. Ordinary SSH/module scheduling overhead is not included in native
command deadlines.

The result is explicitly **one-shot program observation**, not CPU progress,
package health or a stall diagnosis. Recognized phases are apt, dpkg, initramfs
and grub; the most specific recognized phase is shown. State describes the
recognized package programs observed in that scope. `none` means no recognized
package program in that complete direct cgroup snapshot. Unknown programs are
never printed or relabelled as package progress. Child cgroups, unsupported
systems, unreadable data and changing/ambiguous scope produce unavailable package
fields without discarding valid cloud-init status. Newer installations whose
`cloud-final.service` is a forwarding wrapper for another service do not meet
this scope contract; they report unavailable package data instead of inferring
activity from the wrapper.

The prior CPU-delta sampler and `package_cpu_activity`/`package_sample_ms` fields
are removed. There is no inferred `observed` or `not_observed` CPU result. These
reads are not an atomic kernel snapshot; transient changes conservatively refuse
when detected, and no claim about sustained progress is made. Program names can
be changed by guest processes and are not a guest integrity guarantee.

## Direct YAML tests

Run from the catalog root with `ansible-playbook` available on PATH:

```sh
ansible-playbook -i localhost, \
  02_ansible_layer/admin/roles/ansible.utils/tests/cloudinit/run.yml
```

`tests/cloudinit/run.yml` and `case.yml` prepare private local fixtures and invoke
a standalone inner playbook. They substitute only executable/file/wait transport
boundaries in a temporary role copy, never host or guest cloud-init state. The
production 500s/10s policy is asserted before fixture-only waits of zero seconds
for failure cases and one second for the pre-existing success marker.
The inner playbook fails normally; the outer test asserts its nonzero exit and
that later tasks did not run. Callback stdout/stderr remain private and are
checked for synthetic redaction canaries before reporting a named PASS result.

The 17 fixture cases cover executing oneshot and active services, forwarding
wrappers, lost SSH transport, normal/degraded/error JSON, malformed and oversized
status, missing CLI, native timeout, stale prior facts, inactive units, child
cgroups, foreign processes, changed membership, no recognized package program
and a successful boot that skips diagnostics. Available status cases also assert
bounded error counts; every failure case checks the normal report, sanitized
failure task, nonzero inner exit, skipped continuation and redaction canary.

For a private failing-fixture record, pass
`-e cloudinit_test_output=/absolute/private/result.json`; the optional file is
mode0600. This contains synthetic fixture data and should not be published as
production evidence. Fixture directories are removed by `always` cleanup.

Validation on 2026-09-11 with ansible-core 2.19.1: all 17 YAML cases passed
(actual `ansible-playbook` exit 0; outer recap `failed=0`). The 16 failure cases
kept their inner nonzero exits; the success case skipped diagnostics. Evidence:
`/tmp/r42-cloudinit-yaml-final.log` (session40457). The executing-oneshot and
forwarding-wrapper regressions were reproduced before their fixes; their
three-case rerun also passed (`/tmp/r42-cloudinit-yaml-review-green.log`).

Source-only checkpoint: `/tmp/r42-cloudinit-ansible-next-wave`, based on catalog
`0b170a7`. No live guest, deployment, provider or runtime profile was changed.
The former Python collector's historical acceptance applies only to that former
implementation. This YAML replacement needs review and a separately authorized
matching catalog/runtime release before any live acceptance claim.

## Primary contracts

- [Ansible command module](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/command_module.html): argv and registered command results.
- [Cloud-init status CLI](https://docs.cloud-init.io/en/latest/reference/cli.html#status): JSON status and recoverable-error exit code 2.
- [Cloud-init 24.1 cloud-final unit](https://github.com/canonical/cloud-init/blob/24.1/systemd/cloud-final.service.tmpl): the classic executing oneshot service.
- [Linux cgroup v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html): direct process membership and nested group semantics.
- [GNU timeout](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html): command deadlines and forced termination.
