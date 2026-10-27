# software.install.ad_domain_controller

Promote a Windows Server host to the **first domain controller of a new Active Directory
forest**, with the DNS server role, then add the DNS forwarders. Promotion only : OUs, groups and
users belong to `systems.configure.ad_objects`, the domain join of other hosts to
`systems.configure.ad_domain_member`.

Invoked via the thin bundle `range42-playbooks/bundles/admin/software.install.ad_domain_controller/`.

## What it does

1. Asserts the variables (DNS name, NetBIOS name of at most 15 characters, IPv4 forwarders,
   non-empty passwords).
2. Reads `Win32_ComputerSystem.DomainRole`. On a host that is not yet a domain controller :
   - sets the password of the built-in Administrator (found by its RID 500, not by its name) to
     `AD_DC_BUILTIN_ADMIN_PASSWORD`. The promotion turns the local accounts into domain accounts,
     so this value becomes the password of the **domain** Administrator ;
   - copies `C:\Users\<ansible_user>\.ssh\authorized_keys` to
     `C:\ProgramData\ssh\administrators_authorized_keys` and restricts that file to
     Administrators and SYSTEM (`icacls`), so the SSH key of the connection user still works
     after the promotion when `sshd_config` uses the Windows default
     `Match Group administrators` block.
3. `microsoft.ad.domain` : new forest, `install_dns: true`, `reboot: true`
   (`reboot_timeout` 1800 s).
4. Waits until `Get-ADDomain` returns the domain (60 x 10 s).
5. Adds each `AD_DC_DNS_FORWARDERS` entry that `Get-DnsServerForwarder` does not list yet.

A second run on the domain controller skips step 2, `microsoft.ad.domain` reports `ok`, and
step 5 adds nothing. Consequence : a later change of `AD_DC_BUILTIN_ADMIN_PASSWORD` is **not**
applied by a rerun ; change the domain Administrator password with `microsoft.ad.user` or by hand.

## Variables

| Name | Default | Required | Secret | Meaning |
|---|---|---|---|---|
| `AD_DC_DOMAIN` | none | yes | no | DNS name of the new domain, at least two labels (for example `example.lab`) |
| `AD_DC_NETBIOS` | none | yes | no | NetBIOS name of the domain, 1 to 15 letters, digits or hyphens |
| `AD_DC_DSRM_PASSWORD` | none | yes | yes | Directory Services Restore Mode password |
| `AD_DC_BUILTIN_ADMIN_PASSWORD` | none | yes | yes | password set on the built-in Administrator before the promotion, then the domain Administrator password |
| `AD_DC_DNS_FORWARDERS` | `["1.1.1.1"]` | no | no | IPv4 addresses the DNS server forwards external names to |

Both passwords must satisfy the default domain password policy (at least 7 characters, three of
upper case, lower case, digits and symbols). Every task that receives a password runs with
`no_log: true`.

## Requirements

- Windows Server, not yet a member of a domain, with a static IP address.
- Collections `microsoft.ad` (tested with 1.10.0) and `ansible.windows` (tested with 3.5.0).
- Connection : tested over OpenSSH with `ansible_shell_type: powershell`. The connection user
  must be a local administrator ; after the promotion it is a domain account of the same name.

## Security notes

- Before the promotion, the built-in Administrator of a cloned Windows Server image may share
  its password with other accounts of the image. Setting a dedicated value here is what
  separates the domain Administrator from the other accounts.
- The DSRM and Administrator passwords are passed as module arguments only : no task of this
  role writes them to a file or prints them.

## catalog_try

No `catalog_try.yml` : the catalog-try harness deploys Docker elements only today, and this role
targets Windows.
