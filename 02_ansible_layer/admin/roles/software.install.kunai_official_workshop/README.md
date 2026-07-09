# software.install.kunai_official_workshop

Ansible role installing the **CIRCL Kunai official workshop** toolchain on a target
host, turnkey: the operator user runs the exercises, nothing to install or configure
by hand. Mirrors the upstream CIRCL VSS workshop (`kunai-project/workshops`).

Invoked via the thin bundle
`range42-playbooks/bundles/core/software.install.kunai_official_workshop/`.

> A future `software.install.kunai` role is reserved for a clean production install
> of kunai (distinct from this workshop toolchain).

## Tasks

| File | Content |
|---|---|
| `00_packages` | apt: `yara`, `pipx` (+ `jq curl wget gnupg`) |
| `01_pipx_tools` | `pykunai` (as operator user) - `kunai-search`, `kunai-iocgen`, `misp-to-kunai`, `kunai-to-misp`, `kunai-graph` + `~/.local/bin` on the interactive zsh PATH |
| `02_binary` | pinned kunai eBPF binary, GPG-verified, placed in `/usr/local/bin/kunai` |
| `03_config` | `m2k-config.toml` (public CIRCL OSINT feed on ; local `[misp]` block opt-in) |
| `04_boot_seed` | `tmpfiles.d` rule reseeding `/tmp/m2k-config.toml` on boot |

## Variables (see `defaults/main.yml`, resolves the `KUNAI_*` caller vars)

| Caller var | Default | Meaning |
|---|---|---|
| `KUNAI_VERSION` | `v0.6.2` | pinned kunai release tag |
| `KUNAI_ARCH` | `amd64` | binary arch suffix |
| `KUNAI_OPERATOR_USER` | `alice` | user owning the tools + config |
| `KUNAI_PYKUNAI_VERSION` | `0.1.10` | pinned pykunai version |
| `KUNAI_MISP_LOCAL_ENABLE` | `false` | enable local `[misp]` block (set when the local MISP tier is wired) |
| `KUNAI_MISP_URL` / `KUNAI_MISP_KEY` | `""` | local MISP url / reader key (when local enabled) |

## Notes

- The binary is GPG-verified against key `C0F6E8F2C1AB2799A31F416C0548A778D21D10AD`;
  the play aborts if verification fails.
- `kunai install` (systemd capture service) is intentionally skipped to avoid
  conflicting with the interactive `sudo kunai run` used in the exercises.
- Robustness follow-up: the signing key is fetched from a keyserver at deploy time
  (with retry). Embedding the armored key under `files/` would remove that dependency.
