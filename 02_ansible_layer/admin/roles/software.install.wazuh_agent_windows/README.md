# software.install.wazuh_agent_windows

Install the **Wazuh agent** on a Windows host from a pinned MSI, enroll it on a Wazuh manager,
and keep its service running. Only `ansible.windows` modules : no `become`, no fact gathering.

Invoked via the thin bundle `range42-playbooks/bundles/admin/software.install.wazuh_agent_windows/`.

The vendored upstream role `software.install.wazuh-agent` is not used for Windows : its Windows
path needs `become` and gathered facts, writes `ossec.conf` with `template:` (not
`win_template`), and reads a `vars/repo.yml` that the catalog does not carry.

## What it does

1. Asserts the variables. They reach the `msiexec` command line, so only IPv4 addresses, DNS
   names, plain agent names and plain passwords (letters, digits, `.`, `_`, `-`) pass.
2. `ansible.windows.win_get_url` : downloads `WAZUH_AGENT_MSI_URL` to `%TEMP%` of the connection
   account and checks it against `WAZUH_AGENT_MSI_SHA256` (`checksum_algorithm: sha256`). A file
   already there with the right checksum is not downloaded again.
3. `ansible.windows.win_package` : installs the MSI with the properties `WAZUH_MANAGER`,
   `WAZUH_REGISTRATION_SERVER`, `WAZUH_AGENT_NAME` and, when it is not empty,
   `WAZUH_REGISTRATION_PASSWORD`. The module reads the ProductCode from the MSI and does nothing
   when that product is installed. The task runs with `no_log: true`.
4. `ansible.windows.win_service` : `WazuhSvc` running, start type automatic. At its first start
   the agent enrolls on `WAZUH_REGISTRATION_SERVER` (tcp 1515), then reports to `WAZUH_MANAGER`
   (tcp 1514).

The MSI stays in `%TEMP%` : a second run finds it with the right checksum and downloads nothing.

## What it does not change

- An agent that is already installed : the MSI properties apply at install time only, so a new
  `WAZUH_MANAGER` does not reach it. Uninstall the agent first.
- The agent configuration beyond these properties : the `ossec.conf` of the MSI stays as
  shipped (event channels, active response).
- The Windows audit policy : the agent forwards the events that Windows already logs.

## Variables

| Name | Default | Meaning |
|---|---|---|
| `WAZUH_MANAGER` | (required) | address of the manager the agent reports to (tcp 1514) |
| `WAZUH_AGENT_NAME` | (required) | name the agent enrolls with, for example the host name |
| `WAZUH_REGISTRATION_SERVER` | `""` | enrollment server (tcp 1515) ; empty = `WAZUH_MANAGER` |
| `WAZUH_REGISTRATION_PASSWORD` | `""` | enrollment password of the manager (authd `use_password`) ; empty = no password |
| `WAZUH_AGENT_MSI_URL` | `https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.4-1.msi` | the pinned package |
| `WAZUH_AGENT_MSI_SHA256` | `0791a9ee…ead66f` (see `defaults/main.yml`) | SHA-256 of that package |

The version follows the server role `software.install.wazuh` (`VERSION.json` : 4.14.4). Change
the URL and the checksum together. The vendor publishes no usable checksum next to the MSI (the
`.sha512` URL answers 403) : the SHA-256 in the defaults was computed from the file downloaded
over HTTPS from the URL above.

## Enrollment password

Set `WAZUH_REGISTRATION_PASSWORD` when the manager requires a password for enrollment (authd
`use_password: yes`). The range42 server bundle `admin/software.install.wazuh` requires one :
the vault key `infrastructure_wazuh_authd_password`. Without a password on the manager side, any
host that reaches tcp 1515 of the manager can enroll an agent under any free name.

Where the password goes :

- The install task runs with `no_log: true` : the Ansible output does not show the `msiexec`
  arguments, at any verbosity. A failure of this task prints no detail either.
- The `msiexec` command line carries the password while the installer runs. A process that may
  read the command lines of other processes on the host (an administrator) sees it during that
  time.
- The agent keeps the password on disk after the install, to enroll again later (not verified on
  this MSI : check `authd.pass` in the agent install directory). Whoever controls the host can
  read it and enroll other agents on the manager.

Restrict the sources of tcp 1514 and 1515 on the manager as well, for example to the `/32`
addresses of the hosts that run this role : the server bundle does it with ufw.

## Security

- The download goes to `%TEMP%` of the connection account, not to `C:\Windows\Temp`. With the
  default ACL any local user can create a file in `C:\Windows\Temp` and own it. Such a user could
  then replace the MSI between the checksum check and the install, and the installer runs with
  the rights of the connection account.
- The MSI is checked against a SHA-256 pinned in this role. The Authenticode signature is not
  checked.
- The agent opens no listening port. It connects out to the manager on tcp 1514 and 1515.
- The agent runs as `LocalSystem`. A host that runs the agent trusts its manager : with the agent
  configuration as shipped by the MSI, active response is enabled, so the manager can start the
  agent's active-response programs on the host. A compromise of the manager reaches every enrolled
  host, a domain controller included.

## Requirements

- Collection `ansible.windows` (`win_get_url`, `win_package`, `win_service`). Connection : OpenSSH
  with `ansible_shell_type: powershell` and an administrator account.
- Outbound HTTPS from the host to `packages.wazuh.com`.
- The vendor documentation lists Windows 11 and Windows Server 2022 among the supported systems,
  not Windows Server 2025.

## catalog_try

No `catalog_try.yml` : the catalog-try harness deploys Docker elements only today, and this role
targets Windows.
