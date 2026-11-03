# systems.configure.rdp_access

Enable **Remote Desktop** on a Windows host and add accounts to the group "Remote Desktop
Users". Works on a domain member and on a domain controller (on a domain controller the group
step was tested in check mode only).

Invoked via the thin bundle `range42-playbooks/bundles/generic/systems.configure.rdp_access/`.

## What it does

1. Asserts the variables.
2. `ansible.windows.win_regedit` : `HKLM:\System\CurrentControlSet\Control\Terminal Server`,
   `fDenyTSConnections` = `0` (connections allowed).
3. Enables every rule of the Windows Defender Firewall group "Remote Desktop", found by its
   resource string `@FirewallAPI.dll,-28752` (not by its localised name). Fails when the group has
   no rule. On Windows Server 2025 and Windows 11 the group holds three rules : User Mode TCP-In,
   User Mode UDP-In, Shadow TCP-In. The rules keep their profiles and remote addresses.
4. `ansible.windows.win_service` : `TermService` running. Its start type is not changed (Manual
   by default). Measured on Windows Server 2025 and Windows 11 : after `fDenyTSConnections`
   became 0, the service already ran when this task checked it (result `ok`). After a reboot of
   the Windows 11 host, the service ran and the listener on 3389 was back (no reboot measured on
   Windows Server 2025).
5. When `RDP_USERS` is not empty : reads the name of the group with SID `S-1-5-32-555` (localised
   images), then `ansible.windows.win_group_membership` with `state: present` adds `RDP_USERS`.
   Existing members stay. On a member the group is local ; on a domain controller it is the
   built-in domain-local group of the domain (container `CN=Builtin`). The module reaches both
   through the WinNT provider.

A second run reports no change : every task is `ok` or `skipping`.

## What it does not change

- Network Level Authentication (`UserAuthentication` of `RDP-Tcp`), the listening port
  (`PortNumber`, 3389 by default).
- User rights. Membership of "Remote Desktop Users" is enough on a member : there the right
  "Allow log on through Remote Desktop Services" lists Administrators and Remote Desktop Users by
  default. On a domain controller the right lists Administrators only by default (measured on
  Windows Server 2025 : `SeRemoteInteractiveLogonRight = *S-1-5-32-544`), so a member of "Remote
  Desktop Users" still cannot log on to a DC ; use an administrator account there.
- Network firewalls outside the host (for example the Proxmox firewall).

## Variables

| Name | Default | Meaning |
|---|---|---|
| `RDP_USERS` | `[]` | accounts to add to "Remote Desktop Users", for example `["EXAMPLE\\user"]` ; empty = the group is not touched |

No secret : `no_log` is not needed.

## Security

The role widens the host firewall : tcp and udp 3389 (User Mode rules) and the Shadow rule (tcp,
any local port, program `%SystemRoot%\system32\RdpSa.exe`) accept connections, for the
profiles and remote addresses of the built-in rules. On Windows Server 2025 and Windows 11 these
are all profiles and any remote address. Restrict the sources with a network firewall in front of
the host. Every member of the Administrators group can open a Remote Desktop session, also with
the default `RDP_USERS: []` ; every account in `RDP_USERS` can open one on a member.

## Requirements

- Collection `ansible.windows` (tested with 3.5.0). Connection : tested over OpenSSH with
  `ansible_shell_type: powershell` and an administrator account (a local administrator on the
  member, a member of the domain built-in Administrators group on the domain controller).
- Domain accounts in `RDP_USERS` : the host must be a member of the domain, or its domain
  controller, when the role runs.

## catalog_try

No `catalog_try.yml` : the catalog-try harness deploys Docker elements only today, and this role
targets Windows.
