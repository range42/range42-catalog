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
2. Pairs with the hub when the server entry is missing or `testConnection` is not `1`.
3. Sets `push`, `pull`, `push_sightings`, `push_galaxy_clusters`, `pull_galaxy_clusters`. Pins the hub certificate after a pairing, or when the entry has no `cert_file`.
4. Creates the same sharing groups locally.
5. Requires `testConnection` status `1`.

Pairing (`tasks/pair.yml`) revokes **every** key of the team sync user and mints a bootstrap key. It runs `createSync` as the sync user, deletes the bootstrap key (also when `createSync` fails), and then replaces the spoke entry with `servers/import`. Result: one valid key per sync user. A failure at any step is repaired by the next run, because the entry is then missing or `testConnection` is not `1`.

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
- M2 copies every other `perm_*` from role 5, including `perm_auth`. A team can read its sync key on its own spoke. Not verified: whether that key can then mint more keys for the sync user. A re-pair revokes all of them, and disabling the user (T7) blocks all of them.
- A spoke → hub network failure makes `testConnection` fail. Each run then re-pairs (key rotation) and fails at the final check, until the network works again.

## Behaviour to know

- A disabled team sync user (revocation, T7) makes `testConnection` return `4`. The next run then tries to re-pair and fails on that spoke. This is intended, so re-enable the user or remove the spoke from the play.
- A rebuilt hub certificate breaks `testConnection`. The next run re-pairs and pins the new certificate.
- `misp_sync_no_log: false` shows the API results for debugging. Those results contain keys.

## Tested

Lab on 2026-10-13/14 with MISP v2.5.50, one hub and two spokes: first run, two idempotent re-runs (`changed=0`), sync and isolation tests T1, T2, T3, T7, the per-team inject, the hub sighting not reaching a spoke, the negative tests T9c, T9d, T10a, T10b, no key in `-v` output, and a repair after the sync key was deleted.

## Not verified

- `misp_star_inter_team_sharing: true` (`all teams`) on the hub and on the spokes. On a spoke, the group references team orgs that do not exist there, and `sharing_groups/add` is expected to create them by UUID.
- The failure paths inside `pair.yml` (for example `createSync` failing). They were reviewed, not run.
- Whether `sharing_groups/index` also lists inactive groups for a REST call. The M1 scan may skip them.
- `--check` mode: not supported, because the role reads its inputs with `command`.
