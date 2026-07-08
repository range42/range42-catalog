# Vaultwarden (self-hosted credential store)

Self-contained catalog element that runs [Vaultwarden](https://github.com/dani-garcia/vaultwarden)
— a lightweight, Bitwarden-compatible API server written in Rust — as
range42's standardised store for distributing passwords, keys and other
credentials to admins and trainees.

It pairs with the Ansible role
[`credentials.vaultwarden`](../../../../02_ansible_layer/admin/roles/credentials.vaultwarden/)
(get/set), which syncs values between this server and one or more Ansible
vaults. **The vault stays the source of truth; Vaultwarden is a
distribution/sync layer, not a replacement for it.**

> **Naming.** The *server* is **Vaultwarden**. The only place "Bitwarden"
> appears is the *client tool* the role drives — the official Bitwarden CLI
> (`bw`) — because Vaultwarden implements the Bitwarden API. There is no
> cloud/SaaS Bitwarden anywhere in this element: self-hosted only.

## Why Vaultwarden (and the trade-off)

Vaultwarden is a single lightweight container with embedded SQLite — no
external DB, no license-key step — which is why it is the default here. The
alternative, the official `bitwarden/server` "unified" image, is
vendor-supported but a heavier multi-container stack and needs a one-time
online self-host license request. **Both are self-hosted.** The choice is
still an open question (see below); nothing in this element or the role
touches a public endpoint either way.

## Layout

| File | Purpose |
|------|---------|
| `compose.yml` | Vaultwarden service: persistent volume, healthcheck, admin token |
| `.env.example` | Copy to `.env` and fill in — admin token, domain, ports, signups |
| `.gitignore` | Keeps the real `.env` out of git |
| `catalog_try.yml` | Smoke-check contract (`/alive`, port 8080) for catalog-try |
| `Makefile` | `up` / `down` / `hash` / `logs` / `term` / `clean` |

## Deploy (standalone)

```sh
cp .env.example .env
make hash            # generate an argon2 ADMIN_TOKEN, paste it (quoted) into .env
# edit .env: set VW_DOMAIN to how the box is actually reached
make up
```

`compose.yml` refuses to start if `VW_ADMIN_TOKEN` is unset, so a deploy
never silently comes up with an unprotected `/admin` panel. Check health:

```sh
curl -f http://<host>:8080/alive     # 200 + UTC timestamp once serving
```

The admin panel is at `http://<host>:8080/admin` (log in with the *plaintext*
token you hashed, not the hash).

### Deploy inside a scenario

Scenarios do not run `make` — they deploy this directory to a VM via the
`software.configure.docker-compose` role and let it run `docker compose up`,
exactly as `misp_lab` deploys `misp-standalone`. See the companion
`range42-playbooks` bundle `bundles/credentials-vaultwarden/` for the wiring.

## Bootstrap (one-time, manual)

Vaultwarden account and organization creation involve client-side crypto, so
they are **not** auto-provisioned here (doing it wrong would silently create
unusable accounts). One-time steps, done once per instance:

1. **Create the service account.** Temporarily set `VW_SIGNUPS_ALLOWED=true`,
   `make restart`, register one account via the web vault
   (`http://<host>:8080`), then set it back to `false` and `make restart`.
   (Alternatively, invite from the `/admin` panel with invitations enabled.)
2. **Create an organization + collections.** In the web vault, create an org
   (e.g. `range42`) and the collections you want to scope credentials to
   (e.g. `admins`, `trainees`, or per `CODENAME-SCENARIO`). Trainee-vs-admin
   visibility is enforced here, by Vaultwarden collection membership.
3. **Create an API key for the service account.** Account settings → Security
   → Keys → *View API Key* gives a `client_id` / `client_secret`. The role
   uses these (plus the account's master password) to log in non-interactively.

Record the org id (`bw list organizations` once logged in) and hand the
`client_id` / `client_secret` / master password to the role via the vault —
never in plaintext in a playbook.

## How the role consumes this

The `credentials.vaultwarden` role is driven entirely by a caller-supplied
`vaultwarden_sync_map` — no credential names are hardcoded. Example:

```yaml
vaultwarden_url: "http://192.168.142.180:8080"
vaultwarden_organization_id: "{{ vault_vw_org_id }}"        # from vault
vaultwarden_client_id: "{{ vault_vw_client_id }}"           # from vault
vaultwarden_client_secret: "{{ vault_vw_client_secret }}"   # from vault
vaultwarden_master_password: "{{ vault_vw_master_password }}" # from vault

vaultwarden_sync_map:
  # push a vault var INTO Vaultwarden as an item field:
  - vault_var: misp_writer_api_key
    vw_item:   "range42-{{ codename }}-{{ scenario }}-misp"
    vw_field:  writer_api_key
    direction: set
  # pull a centrally-managed value FROM Vaultwarden into a runtime fact:
  - vault_var: shared_service_token
    vw_item:   "range42-org-shared"
    vw_field:  token
    direction: get
```

`set` pushes vault → Vaultwarden; `get` pulls Vaultwarden → an Ansible fact
named after `vault_var`. The role **fails loudly** if the server is
unreachable or a mapped item/field is missing — no silent fallback, because
this is secret distribution. See the role README for the full contract.

## Security notes

- Real `.env` is gitignored; only `.env.example` (placeholders) is committed.
- `SIGNUPS_ALLOWED=false` by default — open it only for the bootstrap step.
- The admin token is stored argon2-hashed in `.env`; the panel login uses the
  plaintext value you hashed.
- The role never logs secrets (`no_log`) and never writes them to disk outside
  existing vault/secrets handling.

## Open questions (tracked on the issue)

- **Vaultwarden vs official Bitwarden self-hosted server** — assumed
  Vaultwarden; confirm before hardening.
- **Auth method** — API key (`client_id`/`client_secret`) is assumed here vs a
  plain email/password login.
- **Scoping** — trainee-vs-admin visibility via Vaultwarden collections
  (external to the role, as above) vs the role knowing about scopes.
- **Conflict resolution** — on `get`, the pulled value currently wins as a
  runtime fact; the vault file is never rewritten.
- **Rotation/polling** — one-shot at provisioning time vs periodic drift sync.
- **Lifecycle** — one shared instance per CODENAME-SCENARIO vs per-scenario.
- **Org/collection bootstrap** — manual (above) vs auto-provisioned.
