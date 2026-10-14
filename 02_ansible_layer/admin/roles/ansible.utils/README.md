# Native guest SSH readiness

`wait/openssh_server/is_reachable.yml` uses the existing SSH configuration and
common/extra SSH arguments, with `BatchMode=yes` and `StrictHostKeyChecking=yes`.
An unknown or changed host key fails readiness. The local Ansible connection
does not open SSH.

Set `range42_guest_hostkey_from_pve_agent: true` to enroll a previously unknown
guest before that same strict wait. This option defaults to false and does
nothing in check mode. It is for qualified Linux guests with an Ed25519 host key,
static IPv4 cloud-init configuration, and a working QEMU guest agent.

The optional step uses the existing native inputs: `global_vm_id`,
`global_vm_name`, `global_vm_ci_ip`, `ARG_vm_ssh_name`, `proxmox_node`,
`proxmox_api_host`, the PVE API user/token variables, and
`deployer_cli_user_ssh_known_hosts`. It requires
`proxmox_api_validate_certs: true`; `RANGE42_PROXMOX_CA_FILE` may provide the
verified PVE CA. It reads the exact VM configuration and only
`/etc/ssh/ssh_host_ed25519_key.pub` through the authenticated PVE
`agent/file-read` GET, with a 4096-byte bound and no HTTP redirects. There is no agent exec or guest
private-key read. VM name, static IP, configuration digest and the effective
SSH destination, port and HostKeyAlias are checked before appending a pin.

The PVE token needs `VM.Audit` to read configuration and
`VM.GuestAgent.FileRead` on the owned VMs. PVE grants FileRead per VM, not per
pathname, so enroll only VMs covered by the qualified template and token scope.
This trusts the PVE control plane and guest agent; it cannot attest an already
compromised guest. It does not require a PVE Linux root SSH key.
The optional controller tasks explicitly disable become, so a guest play's
privilege escalation does not change the local pin owner or PVE CA access.

Pins must be in an absolute path without symlinks, in a directory owned by the
current user/group with mode `0700`. Existing files and the role's adjacent
lock use mode `0600` and the same ownership. The helper locks cooperating
writers, checks the file snapshot again before append, and never replaces or
removes an existing target record. Plain, hashed, revoked and CA-marked target
records remain unchanged; strict SSH decides whether they actually authorize
the server. Standard global trust files (`/etc/ssh/ssh_known_hosts` and
`/etc/ssh/ssh_known_hosts2`) are preserved too. Unknown-target enrollment
requires those standard global paths or `GlobalKnownHostsFile /dev/null`/`none`.

The SSH configuration and common/extra arguments remain trusted controller
configuration. `ssh -G` may evaluate an existing `Match exec` directive; this
step does not make participant-supplied SSH options safe. Configuration
inspection is bounded to five seconds. Existing SSH wrappers and routing
arguments are retained, and the final connection still performs strict host
verification. Key rotation requires an explicit attended update outside this
add-only step.
