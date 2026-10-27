# systems.configure.ad_domain_member

Join a Windows host to an existing **Active Directory domain**, then check the result. Join only :
the domain itself comes from `software.install.ad_domain_controller`, its OUs, groups and users
from `systems.configure.ad_objects`.

Invoked via the thin bundle `range42-playbooks/bundles/generic/systems.configure.ad_domain_member/`.

## What it does

1. Asserts the variables.
2. `ansible.windows.win_dns_client` : every adapter uses `AD_MEMBER_DC_IP` as its only DNS
   server. The join finds the domain through DNS SRV records that only the domain DNS serves.
3. `microsoft.ad.membership` : `state: domain`, `reboot: true` (`reboot_timeout` 1800 s),
   optional target OU.
4. Asserts that `Win32_ComputerSystem.PartOfDomain` is `True` and `Domain` is `AD_MEMBER_DOMAIN`.
5. Asserts that the local built-in Administrator (found by its RID 500) is **disabled** and
   fails otherwise. It is disabled by default on Windows client editions ; when it is enabled it
   is a local administrator account outside the control of the domain.

A rerun on a member reports `ok` for the DNS and the membership tasks.

## Variables

| Name | Default | Required | Secret | Meaning |
|---|---|---|---|---|
| `AD_MEMBER_DOMAIN` | none | yes | no | DNS name of the domain to join |
| `AD_MEMBER_DC_IP` | none | yes | no | IPv4 address of a domain controller that serves the domain DNS |
| `AD_MEMBER_JOIN_USER` | none | yes | no | account allowed to join computers, for example `Administrator@example.lab` |
| `AD_MEMBER_JOIN_PASSWORD` | none | yes | yes | password of `AD_MEMBER_JOIN_USER` |
| `AD_MEMBER_OU` | `""` | no | no | distinguished name of the OU for the computer object ; empty = default `Computers` container. Used only when the host joins, not to move an existing member |

The join task runs with `no_log: true`.

## Requirements

- A Windows host with a static IP address that can reach the domain controller (DNS, Kerberos,
  LDAP, SMB, RPC).
- The computer name must be at most 15 characters (NetBIOS).
- Collections `microsoft.ad` (tested with 1.10.0) and `ansible.windows` (tested with 3.5.0).
- Connection : tested over OpenSSH with `ansible_shell_type: powershell` and a local
  administrator as connection user ; that local account keeps working after the join.

## catalog_try

No `catalog_try.yml` : the catalog-try harness deploys Docker elements only today, and this role
targets Windows.
