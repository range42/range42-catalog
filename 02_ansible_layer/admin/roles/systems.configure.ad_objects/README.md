# systems.configure.ad_objects

Create the **organizational units, groups and users** of an Active Directory domain, on a domain
controller of that domain. Domain content only : the promotion belongs to
`software.install.ad_domain_controller`, the join of other hosts to
`systems.configure.ad_domain_member`.

Invoked via the thin bundle `range42-playbooks/bundles/admin/systems.configure.ad_objects/`.

## What it does

1. Asserts the shape of the three lists.
2. `microsoft.ad.ou` for each `AD_OBJECTS_OUS` entry, then `microsoft.ad.group` for each
   `AD_OBJECTS_GROUPS` entry, then `microsoft.ad.user` for each `AD_OBJECTS_USERS` entry, all
   with `state: present`. OUs come first so that groups and users can live in them, groups before
   users so that a user can join them.
3. A user's password is written only when it differs from the current one
   (`update_password: when_changed`), and the user is added to the listed groups without being
   removed from any other group (`groups.add`).

A rerun with the same lists reports `ok` on every object. The role never deletes an object and
never removes a group membership. With the three lists empty (the default) it changes nothing.

## Variables

| Name | Default | Required | Secret | Meaning |
|---|---|---|---|---|
| `AD_OBJECTS_OUS` | `[]` | no | no | list of `{name, path}` ; `path` (distinguished name of the parent) optional, default the domain root |
| `AD_OBJECTS_GROUPS` | `[]` | no | no | list of `{name, path, scope}` ; `scope` = `domainlocal`, `global` or `universal`, required ; `path` optional, default the default group container |
| `AD_OBJECTS_USERS` | `[]` | no | `password` field : yes | list of `{name, password, path, groups, display_name}` ; `name` and `password` required, the others optional ; `groups` = list of group names to add the user to |

Example :

```yaml
AD_OBJECTS_OUS:
  - { name: "Lab", path: "DC=example,DC=lab" }
AD_OBJECTS_GROUPS:
  - { name: "lab-analysts", path: "OU=Lab,DC=example,DC=lab", scope: "global" }
AD_OBJECTS_USERS:
  - name: "analyst1"
    password: "{{ vault_analyst1_password }}"
    path: "OU=Lab,DC=example,DC=lab"
    groups: ["lab-analysts"]
    display_name: "Analyst One"
```

The user task runs with `no_log: true` : its output hides the user names as well, because the
password is one of the task arguments. Passwords must satisfy the domain password policy.
The `microsoft.ad.user` documentation states that `update_password: when_changed` does not work
for a disabled or expired account (not tested here).

## Requirements

- A domain controller of the target domain (the modules use the local Active Directory
  module and Active Directory Web Services).
- Collection `microsoft.ad` (tested with 1.10.0).

## catalog_try

No `catalog_try.yml` : the catalog-try harness deploys Docker elements only today, and this role
targets Windows.
