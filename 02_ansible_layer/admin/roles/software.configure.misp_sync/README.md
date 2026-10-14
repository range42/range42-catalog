# software.configure.misp_sync

Pairs one `misp-star` hub with N team spokes through the MISP REST API. The role is idempotent. A second run creates no org, user, sharing group or server entry, and it adds no key.

## Play shape

Run the role in **one** play over the hub and every spoke, with `become: true` and the default `linear` strategy. The hub tasks run first, then the spoke tasks. Do not use `serial`, `strategy: free`, or a `--limit` that excludes the hub: the spokes need the facts that the hub publishes in the same play. Each host carries `misp_star_role` (`hub` or `spoke`). Each spoke also carries `misp_star_team`, which is its `MISP_ORG`.

```yaml
- hosts: r42_misp_star_active
  become: true
  gather_facts: false
  roles:
    - software.configure.misp_sync
  vars:
    misp_star_org_uuid_namespace: "<same as MISP_ORG_UUID_NAMESPACE>"
```

Element prerequisites:

- Hub: `MISP_STAR_MODE=hub`, with `MISP_ORG` equal to `MISP_INSTRUCTOR_ORG` (the white cell is the host org). `MISP_TEAMS` lists every spoke team.
- Spoke: `MISP_STAR_MODE=spoke` and `MISP_ORG=<team>`.
- All instances use the same `MISP_ORG_UUID_NAMESPACE`.

## What it does

Hub:

1. Checks that the host org is the white cell and that each team org exists under its name with `uuid5(namespace, name)`.
2. Sets `Plugin.Sightings_policy`: `0` for `push`, `3` for `both`. It never sets `2`.
3. Creates the M2 sync role (see below) if it is missing.
4. Creates the sharing group `<team> -> white cell` for each team, with UUID `uuid5(namespace, 'sharing-group:<team>')`. The `all teams` group is created only when `misp_star_inter_team_sharing: true`.
5. Applies L1 to every hub sharing group, then checks M1 (see below).
6. Creates one sync user per team (`sync-<team>@<misp_sync_user_domain>`) in the team org, and moves existing ones back to the M2 role and the team org.

Spoke:

1. Checks that org 1 is the team org.
2. Pairs with the hub when the server entry is missing, `testConnection` is not `1`, or the team sync user does not have exactly one key on the hub.
3. Sets `push`, `pull`, `push_sightings`, `push_galaxy_clusters`, `pull_galaxy_clusters`. Pins the hub certificate after a pairing, or when the entry has no `cert_file`.
4. Creates the same sharing groups locally.
5. Requires `testConnection` status `1`.

Pairing (`tasks/pair.yml`) revokes **every** key of the team sync user and mints a bootstrap key. It runs `createSync` as the sync user, deletes the bootstrap key (also when `createSync` fails), and then replaces the spoke entry with `servers/import`. Result: one valid key per sync user. A failure at any step is repaired by the next run, because the entry is then missing, `testConnection` is not `1`, or the key count is not `1`.

## Hardening (all three are required)

The sync role has `perm_sharing_group = 1`, and `captureSGExisting` skips authorisation for sync users on `local = 0` groups. Through that path, a team that is admin on its own spoke can read or feed another team over the allowed spoke → hub 443 path (tracking issue: T9, T9c, T9d, T10).

| Control | Implementation | Closes |
|---|---|---|
| M1 | No hub sharing group with two team orgs. The role fails if a star group does not list exactly its expected orgs, or if any listed hub group has two team orgs or an `all_orgs` server entry. The only exception is `all teams` when `misp_star_inter_team_sharing: true`. | T9 |
| M2 | Sync users get `misp_sync_role_name`, a copy of role 5 with `perm_sharing_group = 0`. The role fails if any other `perm_*` differs from role 5. | T9c, T10 (`sharing_groups/add`) |
| L1 | Every hub sharing group gets `local = 1` through a DB update (`mariadb` as root inside the `db` container). REST cannot set it. It runs before any M1 check that can fail, and before any sync user exists. | T9d, T10 |

## Residual risks

- The controls hold at run time only. A hub group created later through REST is `local = 0` until the next run, and an instructor can still create a group with two team orgs. Sync users cannot create groups (M2, lab test T9c), so only a hub admin can open such a gap.
- The role manages only the users `sync-<team>@<misp_sync_user_domain>`. It does not check other hub users that have `perm_sync`.
- M2 keeps `perm_auth` from role 5, because v2.5.50 refuses any API key login without it (`AppController.php:1542`). A team can read its sync key on its own spoke and use it to mint more keys for the sync user (`auth_keys/add`). These keys have the same rights as the sync key. They work until the next run of the role, which re-pairs that spoke and so revokes every key of the user (lab-tested). Disabling the user (T7) blocks all of them at once.
- A spoke → hub network failure makes `testConnection` fail. Each run then re-pairs (key rotation) and fails at the final check, until the network works again.

## Behaviour to know

- A disabled team sync user (revocation, T7) makes `testConnection` return `4`. The next run then tries to re-pair and fails on that spoke. This is intended, so re-enable the user or remove the spoke from the play.
- A rebuilt hub certificate breaks `testConnection`. The next run re-pairs and pins the new certificate.
- `misp_sync_no_log: false` shows the API results for debugging. Those results contain keys.
- `misp_star_inter_team_sharing` and `misp_sync_no_log` must be real booleans. `-e misp_star_inter_team_sharing=true` passes the string `"true"` and the role fails. Use YAML, JSON or `-e @file.yml`.
- `--check` is refused at the first task: the role reads its inputs with `command`, and the API calls cannot be simulated.
- Turning `all teams` off after use: the next run fails on that group (M1). MISP refuses to delete a sharing group that an event, attribute, object or report still uses (`SharingGroup.php` `beforeDelete`). On the hub, delete or re-assign those events first, then delete the group. The spoke copies of the group and of the events stay. A later push of such an event reaches the hub without the group (M2, T9c).

## Tested

Lab on 2026-10-13/14 with MISP v2.5.50, one hub and two spokes:

- First run, and idempotent re-runs (`changed=0`).
- Sync and isolation tests T1, T2, T3, T7, the per-team inject, the hub sighting not reaching a spoke.
- Negative tests T9c, T9d, T10a, T10b. No key in `-v` output.
- Repair after: the sync key was deleted; an extra key was minted for a sync user; the spoke server entry was deleted by hand. Only the affected spoke changes, and each sync user ends with one key.
- `createSync` failing after the bootstrap key was minted: the bootstrap key is deleted, and the spoke entry is not touched.
- M1 scan: a hub group with two team orgs, with an `all_orgs` server entry, or inactive with two team orgs, makes the run fail.
- `misp_star_inter_team_sharing: true`: `all teams` is created on the hub (`local = 1`) and on both spokes (the spokes create the missing team orgs by UUID), a team-01 event in it reaches spoke-02, re-run `changed=0`. Turning it off with the procedure above.

## Not verified

- More than two spokes.
