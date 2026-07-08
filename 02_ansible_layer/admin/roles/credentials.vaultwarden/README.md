# credentials.vaultwarden

Mapping-driven **get/set** sync between an Ansible vault and a self-hosted
[Vaultwarden](https://github.com/dani-garcia/vaultwarden) server.

- **set** — push a vault variable into Vaultwarden as an item's custom field.
- **get** — pull an item's field value from Vaultwarden back into an Ansible
  fact (named after the vault variable).

The vault stays the source of truth; Vaultwarden is the distribution layer.
The role is generic — it hardcodes **no** credential names; everything is
driven by the caller's `vaultwarden_sync_map`.

> **Naming.** The server is **Vaultwarden**. The client the role runs is the
> official **Bitwarden CLI** (`bw`) — the one place "Bitwarden" appears —
> because Vaultwarden implements the Bitwarden API. No cloud endpoint is ever
> used; self-hosted only. Pairs with the container element
> [`03_container_layer/docker/admin/vaultwarden`](../../../../03_container_layer/docker/admin/vaultwarden/).

## Prerequisites (control node)

The role runs `bw` on the **Ansible control node** (`delegate_to: localhost`),
so these must be installed there:

- **Bitwarden CLI** (`bw`) — `npm i -g @bitwarden/cli`, snap, or the release binary.
- **jq**.

The role fails loudly if either is missing.

## Variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `vaultwarden_url` | ✅ | Vaultwarden base URL (its own container, by convention) |
| `vaultwarden_client_id` | ✅ | Personal API-key `client_id` |
| `vaultwarden_client_secret` | ✅ | Personal API-key `client_secret` |
| `vaultwarden_master_password` | ✅ | Account master password (to unlock the vault) |
| `vaultwarden_organization_id` | — | Scope items to an org |
| `vaultwarden_collection_id` | — | Collection id (required by Vaultwarden for org items) |
| `vaultwarden_sync_map` | ✅ | The list of get/set entries (below) |
| `vaultwarden_debug` | — | `true` disables `no_log` for debugging (leaks secrets to output) |

Supply the four secret values from a **vault**, never inline.

## Mapping format

```yaml
vaultwarden_sync_map:
  - vault_var: misp_writer_api_key          # source var for set
    vw_item:   "range42-{{ codename }}-misp"
    vw_field:  writer_api_key
    direction: set

  - vault_var: shared_service_token         # fact name for get
    vw_item:   "range42-org-shared"
    vw_field:  token
    direction: get
```

## Usage

```yaml
- name: sync credentials with Vaultwarden
  hosts: localhost            # or any host - the engine runs on localhost anyway
  gather_facts: false
  roles:
    - role: credentials.vaultwarden
      vars:
        vaultwarden_url: "http://192.168.142.180:8080"
        vaultwarden_client_id: "{{ vault_vw_client_id }}"
        vaultwarden_client_secret: "{{ vault_vw_client_secret }}"
        vaultwarden_master_password: "{{ vault_vw_master_password }}"
        vaultwarden_organization_id: "{{ vault_vw_org_id | default('') }}"
        vaultwarden_collection_id: "{{ vault_vw_collection_id | default('') }}"
        vaultwarden_sync_map: "{{ my_scenario_sync_map }}"
```

After the role runs, each `get` value is available two ways:

- as a fact named after its `vault_var` (e.g. `{{ shared_service_token }}`), and
- collected together in `{{ vaultwarden_get_results }}` (a dict).

> ⚠️ **These facts hold raw secret values for the rest of the play.** `no_log`
> only masks *this* role's output — it does not tag the facts as sensitive.
> Any later task that dumps variables (`debug: var=...`, `-vvv`, a failing task,
> a callback plugin) can leak them. Keep `no_log` discipline on any task that
> reads them, and unset them once used. The role scrubs its own intermediate
> plan (`_vw_plan_entries`) automatically.

## Behaviour & guarantees

- **Fails loudly, no silent fallback** — missing `bw`/`jq`, an unreachable
  server, a bad login, an ambiguous item name, or a missing item/field on a
  `get` all abort the run with a clear message (containing **no** secret
  values). This is deliberate: it is secret distribution.
- **set is create-or-update** — the field is upserted on an existing item, or
  a new login-type item is created carrying it.
- **Secrets never hit argv** — connection secrets go via the environment,
  `set` values via stdin; `no_log` is on by default. The engine writes no
  secrets to disk. ⚠️ One caveat outside the engine's control: Ansible's
  `command` module (AnsiballZ) may briefly stage the delegated env/stdin in a
  temp module file under `~/.ansible/tmp/`. Do **not** run this role with
  `ANSIBLE_KEEP_REMOTE_FILES=1` or `-vvvv`, which would preserve that file.
- **No developer-session clobber** — the engine uses a private, throwaway
  `BITWARDENCLI_APPDATA_DIR` and logs out on exit, so it never touches a real
  `bw` session on the control node. A `SIGKILL`/crash can't run the cleanup
  trap, so on start the engine also purges its own leftover appdata dirs
  (`$TMPDIR/vw_sync_bw_appdata.*`) older than a day — no external cron needed.

## Implementation note

Unlike the split hinted at in the tracking issue (`tasks/get.yml` /
`tasks/set.yml`), the get/set logic lives in a single engine script
[`files/vw_sync.sh`](files/vw_sync.sh). This keeps the `bw`
login → unlock → operate → logout session atomic within one process and keeps
all secret handling in one small, reviewable place, rather than threading a
`BW_SESSION` through multiple Ansible tasks.

## Open questions

Tracked on the issue — auth method, trainee/admin scoping, conflict
resolution, one-shot vs polling, shared vs per-scenario instance, and
org/collection bootstrap. See the container element README.
