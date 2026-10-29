# systems.configure.windows_eval_activation

Activate a **Windows evaluation edition** online and check the result. Activation only : no
product key is installed, the role uses the evaluation key already in the image.

Invoked via the thin bundle `range42-playbooks/bundles/generic/systems.configure.windows_eval_activation/`.

## Why

`sysprep /generalize` rearms the licensing state. A clone of an evaluation template therefore
starts with an expired grace period : Software Protection reports status code `0xC004F009` in
Application event 1003. The clone must complete one online time-based activation. Windows tries it
automatically at boot (`slui.exe`, event 8198) ; when that attempt fails, the next automatic attempt
is one day later. Meanwhile the Windows Licensing Monitoring Service (`wlms.exe`) shuts the host
down 60 minutes after each boot (System event 1074 by `wlms.exe`, WLMS event 101 "The license
period for this installation of Windows has expired").

Measured on a Windows 11 Enterprise evaluation clone (build 26300) whose only DNS server was a
domain controller that did not resolve external names at boot : the automatic activation failed
with event 8200 `hr=0x80072EE7` (name not resolved), and `wlms.exe` shut the clone down 60 minutes
after boot. At a later boot, with working DNS, the same clone activated about one minute after
boot.

## What it does

1. Asserts the variables.
2. Reads `SoftwareLicensingProduct` of Windows (`LicenseStatus`, `GracePeriodRemaining` in
   minutes). These are the values that `slmgr.vbs /xpr` prints as localised text.
3. When the host is not licensed with more than one day (1440 minutes) left : runs
   `cscript //nologo %WINDIR%\System32\slmgr.vbs /ato`, reads the state again. It repeats this
   step until the host is licensed with more than one day left : at most
   `WIN_EVAL_ACTIVATION_RETRIES` + 1 attempts, `WIN_EVAL_ACTIVATION_DELAY` seconds apart. The task
   output holds the `slmgr.vbs /xpr` text of the last attempt.
4. When no attempt succeeds : reads the newest Application event 8200 (Software Protection) since
   the start of the role and fails with its `hr=0x...` code and the output of the last attempt.
   Without such an event, the message says that no event 8200 was found.

A host already licensed with more than one day left reports `ok` and runs no activation.

## Variables

| Name | Default | Meaning |
|---|---|---|
| `WIN_EVAL_ACTIVATION_RETRIES` | `10` | attempts after the first one (integer, at least 1) |
| `WIN_EVAL_ACTIVATION_DELAY` | `60` | seconds between two attempts (integer) |

No secret : `no_log` is not needed.

## Requirements

- The host reaches the Microsoft activation servers : outbound HTTPS and a DNS server that resolves
  external names. A host whose DNS server is a domain controller needs a DNS forwarder on that DC,
  so run this role after the DC has its forwarder.
- Collection `ansible.windows` (tested with 3.5.0). Connection : tested over OpenSSH with
  `ansible_shell_type: powershell` and a local administrator.

## catalog_try

No `catalog_try.yml` : the catalog-try harness deploys Docker elements only today, and this role
targets Windows.
